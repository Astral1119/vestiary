#!/usr/bin/env python3

import contextlib
import datetime
import hashlib
import json
import os
import pathlib
import re
import secrets
import stat


MANIFEST_VERSION = 1
MANIFEST_VERSIONS = {1, 2}
RESULT_VERSION = 1
RESULT_VERSIONS = {1, 2, 3}
CATALOG_PATH = pathlib.Path(__file__).with_name("workloads-v1.json")
HASH_PATTERN = re.compile(r"^[0-9a-f]{64}$")
TOKEN_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
ROLES = {"automation", "operator", "root-agent", "subagent"}
PURPOSES = {"correctness", "lifecycle", "profiling"}
PRIVATE_PATH_PATTERN = re.compile(
    r"(?:^|\s)(?:/|~[/\\]|[A-Za-z]:[/\\])|/Users/|/home/|[A-Za-z]:[/\\]Users[/\\]"
)


class ContractError(ValueError):
    pass


def _duplicate_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ContractError(f"duplicate JSON field: {key}")
        result[key] = value
    return result


def load_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle, object_pairs_hook=_duplicate_object)


def canonical_json_bytes(value):
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def canonical_hash(value):
    return hashlib.sha256(canonical_json_bytes(value)).hexdigest()


def _object(value, path, required, optional=()):
    if not isinstance(value, dict):
        raise ContractError(f"{path} must be an object")
    required = set(required)
    allowed = required | set(optional)
    missing = sorted(required - set(value))
    unknown = sorted(set(value) - allowed)
    if missing:
        raise ContractError(f"{path} is missing: {', '.join(missing)}")
    if unknown:
        raise ContractError(f"{path} has unknown fields: {', '.join(unknown)}")
    return value


def _array(value, path, *, minimum=0):
    if not isinstance(value, list) or len(value) < minimum:
        raise ContractError(f"{path} must be an array with at least {minimum} items")
    return value


def _string(value, path, *, token=False):
    if not isinstance(value, str) or not value:
        raise ContractError(f"{path} must be a nonempty string")
    if token and TOKEN_PATTERN.fullmatch(value) is None:
        raise ContractError(f"{path} must be a lowercase identifier")
    return value


def _integer(value, path, *, minimum=0, positive=False):
    if isinstance(value, bool) or not isinstance(value, int):
        raise ContractError(f"{path} must be an integer")
    floor = 1 if positive else minimum
    if value < floor:
        raise ContractError(f"{path} must be at least {floor}")
    return value


def _boolean(value, path):
    if not isinstance(value, bool):
        raise ContractError(f"{path} must be a Boolean")
    return value


def _availability(value, path):
    """A measured field the sampler may or may not have supplied:
    `{available: false}` for an explicit gap, `{available: true, value: ...}`
    for a real reading. A profiling verdict treats a required-but-unavailable
    metric as a validity failure, never as a zero measurement."""
    _object(value, path, {"available"}, optional={"value"})
    available = _boolean(value["available"], f"{path}.available")
    if available and "value" not in value:
        raise ContractError(f"{path} is available but carries no value")
    if not available and "value" in value:
        raise ContractError(f"{path} is unavailable but carries a value")
    return available


def _hash(value, path):
    if not isinstance(value, str) or HASH_PATTERN.fullmatch(value) is None:
        raise ContractError(f"{path} must be a lowercase SHA-256 digest")
    return value


def _utc(value, path):
    _string(value, path)
    if not value.endswith("Z"):
        raise ContractError(f"{path} must use UTC with a Z suffix")
    try:
        parsed = datetime.datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise ContractError(f"{path} must be an RFC 3339 timestamp") from error
    if parsed.tzinfo != datetime.timezone.utc:
        raise ContractError(f"{path} must be UTC")
    return parsed


def _catalog():
    catalog = load_json(CATALOG_PATH)
    _object(catalog, "catalog", {"schemaVersion", "workloads"})
    if catalog["schemaVersion"] != 1:
        raise ContractError("unsupported workload catalog version")
    result = {}
    for index, item in enumerate(_array(catalog["workloads"], "catalog.workloads")):
        path = f"catalog.workloads[{index}]"
        _object(item, path, {"identity", "classification", "implementation"})
        identity = _string(item["identity"], f"{path}.identity", token=True)
        if identity in result:
            raise ContractError(f"duplicate workload identity: {identity}")
        if item["classification"] not in {"primary", "deferred"}:
            raise ContractError(f"{path}.classification is invalid")
        if item["implementation"] not in {
            "contract-only",
            "adapter-baseline",
            "implemented",
        }:
            raise ContractError(f"{path}.implementation is invalid")
        result[identity] = item
    return result


WORKLOADS = _catalog()


def _validate_hash_items(items, path):
    seen = set()
    for index, item in enumerate(_array(items, path, minimum=1)):
        item_path = f"{path}[{index}]"
        _object(item, item_path, {"identity", "sha256", "bytes"})
        identity = _string(item["identity"], f"{item_path}.identity", token=True)
        if identity in seen:
            raise ContractError(f"{path} contains duplicate identity {identity}")
        seen.add(identity)
        _hash(item["sha256"], f"{item_path}.sha256")
        _integer(item["bytes"], f"{item_path}.bytes")


DERIVED_ARTIFACT_RELATIONSHIP_FIELDS = {
    "identity",
    "generatorAsset",
    "parametersInput",
    "artifact",
    "comparisonArtifact",
    "generatorBinaryArtifact",
    "byteReproducible",
}


def _validate_derived_artifact_declarations(manifest):
    if "derivedArtifacts" not in manifest:
        return
    asset_ids = {item["identity"] for item in manifest["assets"]}
    input_ids = {item["identity"] for item in manifest["inputs"]}
    seen = set()
    for index, declaration in enumerate(
        _array(manifest["derivedArtifacts"], "manifest.derivedArtifacts", minimum=1)
    ):
        path = f"manifest.derivedArtifacts[{index}]"
        _object(declaration, path, DERIVED_ARTIFACT_RELATIONSHIP_FIELDS)
        identity = _string(declaration["identity"], f"{path}.identity", token=True)
        if identity in seen:
            raise ContractError(f"duplicate derived artifact identity: {identity}")
        seen.add(identity)
        generator_asset = _string(
            declaration["generatorAsset"], f"{path}.generatorAsset", token=True
        )
        if generator_asset not in asset_ids:
            raise ContractError(f"{path}.generatorAsset references unknown asset")
        parameters_input = _string(
            declaration["parametersInput"], f"{path}.parametersInput", token=True
        )
        if parameters_input not in input_ids:
            raise ContractError(f"{path}.parametersInput references unknown input")
        artifact_names = []
        for field in ("artifact", "comparisonArtifact", "generatorBinaryArtifact"):
            artifact_names.append(
                _string(declaration[field], f"{path}.{field}", token=True)
            )
        if len(set(artifact_names)) != len(artifact_names):
            raise ContractError(f"{path} artifact references must be distinct")
        if _boolean(declaration["byteReproducible"], f"{path}.byteReproducible"):
            raise ContractError(f"{path}.byteReproducible must be false")


def validate_manifest(manifest):
    _object(
        manifest,
        "manifest",
        {
            "schemaVersion",
            "workload",
            "criteriaVersion",
            "assets",
            "inputs",
            "reference",
            "seed",
            "checkpoints",
            "invariants",
        },
        {"derivedArtifacts"},
    )
    if manifest["schemaVersion"] not in MANIFEST_VERSIONS:
        raise ContractError("unsupported workload manifest version")
    if manifest["schemaVersion"] == 1 and "derivedArtifacts" in manifest:
        raise ContractError(
            "workload manifest version 1 does not support derived artifacts"
        )
    workload = _object(
        manifest["workload"],
        "manifest.workload",
        {"identity", "version", "classification"},
    )
    identity = _string(workload["identity"], "manifest.workload.identity", token=True)
    if identity not in WORKLOADS:
        raise ContractError(f"unknown workload identity: {identity}")
    if workload["classification"] != WORKLOADS[identity]["classification"]:
        raise ContractError("workload classification contradicts the catalog")
    _integer(workload["version"], "manifest.workload.version", positive=True)
    _string(manifest["criteriaVersion"], "manifest.criteriaVersion", token=True)
    _validate_hash_items(manifest["assets"], "manifest.assets")
    _validate_hash_items(manifest["inputs"], "manifest.inputs")
    _validate_hash_items([manifest["reference"]], "manifest.reference")
    _validate_derived_artifact_declarations(manifest)
    _integer(manifest["seed"], "manifest.seed")

    checkpoint_ids = set()
    previous_time = -1
    for index, checkpoint in enumerate(
        _array(manifest["checkpoints"], "manifest.checkpoints", minimum=1)
    ):
        path = f"manifest.checkpoints[{index}]"
        _object(checkpoint, path, {"identity", "atNanoseconds", "invariants"})
        checkpoint_id = _string(checkpoint["identity"], f"{path}.identity", token=True)
        if checkpoint_id in checkpoint_ids:
            raise ContractError(f"duplicate checkpoint identity: {checkpoint_id}")
        checkpoint_ids.add(checkpoint_id)
        at = _integer(checkpoint["atNanoseconds"], f"{path}.atNanoseconds")
        if at < previous_time:
            raise ContractError("checkpoint times must be nondecreasing")
        previous_time = at
        invariant_ids = _array(checkpoint["invariants"], f"{path}.invariants", minimum=1)
        checkpoint_invariants = set()
        for invariant_index, invariant_id in enumerate(invariant_ids):
            _string(
                invariant_id,
                f"{path}.invariants[{invariant_index}]",
                token=True,
            )
            if invariant_id in checkpoint_invariants:
                raise ContractError(
                    f"{path}.invariants contains duplicate identity {invariant_id}"
                )
            checkpoint_invariants.add(invariant_id)

    invariant_ids = set()
    for index, invariant in enumerate(
        _array(manifest["invariants"], "manifest.invariants", minimum=1)
    ):
        path = f"manifest.invariants[{index}]"
        _object(invariant, path, {"identity", "description"})
        invariant_id = _string(invariant["identity"], f"{path}.identity", token=True)
        if invariant_id in invariant_ids:
            raise ContractError(f"duplicate invariant identity: {invariant_id}")
        invariant_ids.add(invariant_id)
        _string(invariant["description"], f"{path}.description")
    for checkpoint in manifest["checkpoints"]:
        unknown = set(checkpoint["invariants"]) - invariant_ids
        if unknown:
            raise ContractError(
                "checkpoint references unknown invariants: " + ", ".join(sorted(unknown))
            )
    return manifest


def manifest_hash(manifest):
    validate_manifest(manifest)
    return canonical_hash(manifest)


def _metric(value, path, *, positive=False):
    _object(value, path, {"status"}, {"value", "reason"})
    if value["status"] == "unavailable":
        if set(value) != {"status", "reason"}:
            raise ContractError(f"{path} unavailable metric has invalid fields")
        _string(value["reason"], f"{path}.reason")
        raise ContractError(f"{path} is required but unavailable")
    if value["status"] != "available" or set(value) != {"status", "value"}:
        raise ContractError(f"{path} must be an available metric")
    return _integer(value["value"], f"{path}.value", positive=positive)


def _validate_artifacts(artifacts):
    by_name = {}
    for index, artifact in enumerate(_array(artifacts, "record.artifacts", minimum=1)):
        path = f"record.artifacts[{index}]"
        _object(artifact, path, {"name", "mediaType", "sha256", "bytes", "path"})
        name = _string(artifact["name"], f"{path}.name", token=True)
        if name in by_name:
            raise ContractError(f"duplicate artifact name: {name}")
        _string(artifact["mediaType"], f"{path}.mediaType")
        digest = _hash(artifact["sha256"], f"{path}.sha256")
        _integer(artifact["bytes"], f"{path}.bytes")
        expected_path = f"artifacts/sha256/{digest[:2]}/{digest}"
        if artifact["path"] != expected_path:
            raise ContractError(f"{path}.path is not the content-addressed path")
        by_name[name] = artifact
    return by_name


def _artifact_references(values, path, artifacts, *, minimum=1):
    seen = set()
    for index, name in enumerate(_array(values, path, minimum=minimum)):
        name = _string(name, f"{path}[{index}]", token=True)
        if name in seen:
            raise ContractError(f"{path} contains duplicate artifact {name}")
        if name not in artifacts:
            raise ContractError(f"{path} references unknown artifact {name}")
        seen.add(name)


def _validate_run(run):
    _object(
        run,
        "record.run",
        {
            "identity",
            "startedAtUtc",
            "completedAtUtc",
            "operator",
            "agentRole",
            "purpose",
            "sourceSha256",
            "binarySha256",
            "workload",
            "manifestSha256",
            "assets",
            "inputs",
            "seed",
        },
    )
    _string(run["identity"], "record.run.identity", token=True)
    started = _utc(run["startedAtUtc"], "record.run.startedAtUtc")
    completed = _utc(run["completedAtUtc"], "record.run.completedAtUtc")
    if completed < started:
        raise ContractError("record.run completion precedes start")
    _string(run["operator"], "record.run.operator")
    if run["agentRole"] not in ROLES:
        raise ContractError("record.run.agentRole is invalid")
    if run["purpose"] not in PURPOSES:
        raise ContractError("record.run.purpose is invalid")
    if run["purpose"] == "profiling" and run["agentRole"] == "subagent":
        raise ContractError("subagents cannot produce profiling records")
    _hash(run["sourceSha256"], "record.run.sourceSha256")
    _hash(run["binarySha256"], "record.run.binarySha256")
    workload = _object(
        run["workload"], "record.run.workload", {"identity", "version"}
    )
    identity = _string(workload["identity"], "record.run.workload.identity", token=True)
    if identity not in WORKLOADS:
        raise ContractError(f"unknown workload identity: {identity}")
    _integer(workload["version"], "record.run.workload.version", positive=True)
    _hash(run["manifestSha256"], "record.run.manifestSha256")
    _validate_hash_items(run["assets"], "record.run.assets")
    _validate_hash_items(run["inputs"], "record.run.inputs")
    _integer(run["seed"], "record.run.seed")


def _validate_candidate(candidate):
    _object(
        candidate,
        "record.candidate",
        {"identity", "backend", "graphicsApi", "shaderApi"},
    )
    for field in ("identity", "backend", "graphicsApi", "shaderApi"):
        _string(candidate[field], f"record.candidate.{field}", token=True)


def _validate_build(build, run, artifacts):
    _object(
        build,
        "record.build",
        {"identity", "sourceSha256", "binarySha256", "commands", "artifacts"},
    )
    _string(build["identity"], "record.build.identity", token=True)
    if _hash(build["sourceSha256"], "record.build.sourceSha256") != run["sourceSha256"]:
        raise ContractError("build source hash contradicts run source hash")
    if _hash(build["binarySha256"], "record.build.binarySha256") != run["binarySha256"]:
        raise ContractError("build binary hash contradicts run binary hash")
    for index, command in enumerate(_array(build["commands"], "record.build.commands", minimum=1)):
        _string(command, f"record.build.commands[{index}]")
    _artifact_references(build["artifacts"], "record.build.artifacts", artifacts)


def _validate_host_display_policy(record):
    host = _object(record["host"], "record.host", {"os", "architecture"})
    _string(host["os"], "record.host.os")
    _string(host["architecture"], "record.host.architecture", token=True)
    display = _object(
        record["display"],
        "record.display",
        {
            "logicalWidth",
            "logicalHeight",
            "pixelWidth",
            "pixelHeight",
            "scaleMilli",
            "maximumRefreshMilliHertz",
            "colorSpace",
        },
    )
    for field in (
        "logicalWidth",
        "logicalHeight",
        "pixelWidth",
        "pixelHeight",
        "scaleMilli",
        "maximumRefreshMilliHertz",
    ):
        _integer(display[field], f"record.display.{field}", positive=True)
    _string(display["colorSpace"], "record.display.colorSpace")
    policy = _object(
        record["policy"],
        "record.policy",
        {"revision", "fpsCeiling", "active", "schedulerMode"},
    )
    _integer(policy["revision"], "record.policy.revision")
    _integer(policy["fpsCeiling"], "record.policy.fpsCeiling", positive=True)
    _boolean(policy["active"], "record.policy.active")
    _string(policy["schedulerMode"], "record.policy.schedulerMode", token=True)


def _validate_execution(execution):
    fields = {
        "invalidations",
        "evaluations",
        "submissions",
        "presents",
        "suppressedPresents",
        "missedDeadlines",
    }
    _object(execution, "record.execution", fields)
    for field in fields:
        _metric(execution[field], f"record.execution.{field}")


PROFILE_METRICS = {
    "cpuPowerMilliwatts",
    "gpuPowerMilliwatts",
    "gpuActiveResidency",
    "wakeups",
    "contextSwitches",
    "energyImpact",
    "thermalPressure",
    "memoryBytes",
}

# A valid measurement must supply these; their absence forces validity false.
# Energy Impact is intentionally not required: some macOS builds report it null
# per task. The component CPU and GPU powers plus wakeups carry the attribution.
PROFILE_REQUIRED_METRICS = {
    "cpuPowerMilliwatts",
    "gpuPowerMilliwatts",
    "wakeups",
}


def _validate_profile(profile, artifacts, run):
    _object(
        profile,
        "record.profile",
        {
            "validity",
            "invalidReasons",
            "trialOrder",
            "quiescenceManifest",
            "metrics",
            "rawArtifacts",
        },
    )
    valid = _boolean(profile["validity"], "record.profile.validity")

    reasons = _array(profile["invalidReasons"], "record.profile.invalidReasons")
    for index, reason in enumerate(reasons):
        _string(reason, f"record.profile.invalidReasons[{index}]")
    if valid and reasons:
        raise ContractError("a valid profiling record carries no invalid reasons")
    if not valid and not reasons:
        raise ContractError("an invalid profiling record must state a reason")

    order = _array(profile["trialOrder"], "record.profile.trialOrder", minimum=1)
    for index, phase in enumerate(order):
        _string(phase, f"record.profile.trialOrder[{index}]", token=True)
    if "candidate" not in order:
        raise ContractError("record.profile.trialOrder must include the candidate phase")

    manifest = _object(
        profile["quiescenceManifest"],
        "record.profile.quiescenceManifest",
        {
            "powerSource",
            "lowPowerMode",
            "thermalWarning",
            "colorSpace",
            "displayRefreshMilliHertz",
            "ownershipClean",
            "strayProcessCount",
        },
    )
    _availability(manifest["powerSource"], "record.profile.quiescenceManifest.powerSource")
    _availability(manifest["lowPowerMode"], "record.profile.quiescenceManifest.lowPowerMode")
    _availability(manifest["thermalWarning"], "record.profile.quiescenceManifest.thermalWarning")
    _string(manifest["colorSpace"], "record.profile.quiescenceManifest.colorSpace")
    _integer(
        manifest["displayRefreshMilliHertz"],
        "record.profile.quiescenceManifest.displayRefreshMilliHertz",
        positive=True,
    )
    ownership_clean = _boolean(
        manifest["ownershipClean"], "record.profile.quiescenceManifest.ownershipClean"
    )
    _integer(
        manifest["strayProcessCount"],
        "record.profile.quiescenceManifest.strayProcessCount",
    )

    metrics = _object(profile["metrics"], "record.profile.metrics", PROFILE_METRICS)
    availability = {
        name: _availability(metrics[name], f"record.profile.metrics.{name}")
        for name in PROFILE_METRICS
    }

    references = _array(profile["rawArtifacts"], "record.profile.rawArtifacts")
    for index, name in enumerate(references):
        artifact = _string(name, f"record.profile.rawArtifacts[{index}]", token=True)
        if artifact not in artifacts:
            raise ContractError(
                f"record.profile.rawArtifacts references unknown artifact {artifact}"
            )

    # Validity must reflect the recorded conditions, so an invalid-marked
    # dev run cannot masquerade as a clean baseline and a clean baseline
    # cannot hide a real gap.
    missing_required = sorted(
        name for name in PROFILE_REQUIRED_METRICS if not availability[name]
    )
    if valid:
        if not ownership_clean:
            raise ContractError("a valid profiling record requires clean ownership")
        if manifest["strayProcessCount"] != 0:
            raise ContractError("a valid profiling record requires zero stray processes")
        if missing_required:
            raise ContractError(
                "a valid profiling record requires metrics: "
                + ", ".join(missing_required)
            )
    else:
        if not ownership_clean and "ownership-violation" not in reasons:
            raise ContractError("unclean ownership must be stated as an invalid reason")
        if missing_required and not any(
            "metric" in reason for reason in reasons
        ):
            raise ContractError(
                "unavailable required metrics must be stated as an invalid reason"
            )


def _validate_generated_artifacts(generated, artifacts, run):
    asset_ids = {item["identity"] for item in run["assets"]}
    input_ids = {item["identity"] for item in run["inputs"]}
    seen = set()
    for index, item in enumerate(
        _array(generated, "record.correctness.generatedArtifacts", minimum=1)
    ):
        path = f"record.correctness.generatedArtifacts[{index}]"
        _object(
            item,
            path,
            DERIVED_ARTIFACT_RELATIONSHIP_FIELDS
            | {"actualSha256", "comparisonSha256", "byteIdentical"},
        )
        identity = _string(item["identity"], f"{path}.identity", token=True)
        if identity in seen:
            raise ContractError(f"duplicate generated artifact identity: {identity}")
        seen.add(identity)
        generator_asset = _string(
            item["generatorAsset"], f"{path}.generatorAsset", token=True
        )
        if generator_asset not in asset_ids:
            raise ContractError(f"{path}.generatorAsset references unknown run asset")
        parameters_input = _string(
            item["parametersInput"], f"{path}.parametersInput", token=True
        )
        if parameters_input not in input_ids:
            raise ContractError(f"{path}.parametersInput references unknown run input")
        artifact_names = []
        for field in ("artifact", "comparisonArtifact", "generatorBinaryArtifact"):
            name = _string(item[field], f"{path}.{field}", token=True)
            if name not in artifacts:
                raise ContractError(f"{path}.{field} references unknown artifact {name}")
            artifact_names.append(name)
        if len(set(artifact_names)) != len(artifact_names):
            raise ContractError(f"{path} artifact references must be distinct")
        if _boolean(item["byteReproducible"], f"{path}.byteReproducible"):
            raise ContractError(f"{path}.byteReproducible must be false")
        actual_digest = _hash(item["actualSha256"], f"{path}.actualSha256")
        comparison_digest = _hash(
            item["comparisonSha256"], f"{path}.comparisonSha256"
        )
        _boolean(item["byteIdentical"], f"{path}.byteIdentical")
        if actual_digest != artifacts[item["artifact"]]["sha256"]:
            raise ContractError(f"{path}.actualSha256 contradicts artifact digest")
        if comparison_digest != artifacts[item["comparisonArtifact"]]["sha256"]:
            raise ContractError(f"{path}.comparisonSha256 contradicts artifact digest")
        if item["byteIdentical"] != (actual_digest == comparison_digest):
            raise ContractError(f"{path}.byteIdentical contradicts artifact digests")


def _validate_correctness(correctness, artifacts, run):
    _object(
        correctness,
        "record.correctness",
        {"reference", "checkpoints", "semanticAssertions", "graphicsErrors", "artifacts"},
        {"generatedArtifacts"},
    )
    _validate_hash_items([correctness["reference"]], "record.correctness.reference")
    for collection in ("checkpoints", "semanticAssertions"):
        seen = set()
        for index, assertion in enumerate(
            _array(correctness[collection], f"record.correctness.{collection}", minimum=1)
        ):
            path = f"record.correctness.{collection}[{index}]"
            required = {"identity", "passed", "artifact"}
            if collection == "checkpoints":
                required.add("invariants")
            _object(assertion, path, required)
            identity = _string(assertion["identity"], f"{path}.identity", token=True)
            if identity in seen:
                raise ContractError(f"duplicate {collection} identity: {identity}")
            seen.add(identity)
            _boolean(assertion["passed"], f"{path}.passed")
            artifact = _string(assertion["artifact"], f"{path}.artifact", token=True)
            if artifact not in artifacts:
                raise ContractError(f"{path} references unknown artifact {artifact}")
            if collection == "checkpoints":
                invariant_ids = _array(
                    assertion["invariants"], f"{path}.invariants", minimum=1
                )
                seen_invariants = set()
                for invariant_index, invariant_id in enumerate(invariant_ids):
                    invariant_id = _string(
                        invariant_id,
                        f"{path}.invariants[{invariant_index}]",
                        token=True,
                    )
                    if invariant_id in seen_invariants:
                        raise ContractError(
                            f"{path}.invariants contains duplicate {invariant_id}"
                        )
                    seen_invariants.add(invariant_id)
    _metric(correctness["graphicsErrors"], "record.correctness.graphicsErrors")
    _artifact_references(
        correctness["artifacts"], "record.correctness.artifacts", artifacts
    )
    if "generatedArtifacts" in correctness:
        _validate_generated_artifacts(correctness["generatedArtifacts"], artifacts, run)


def _validate_shaders(shaders, artifacts):
    _object(
        shaders,
        "record.shaders",
        {"conditioningSchemaVersion", "compilations", "pipelineCreations", "diagnostics"},
    )
    _integer(
        shaders["conditioningSchemaVersion"],
        "record.shaders.conditioningSchemaVersion",
        positive=True,
    )
    _metric(shaders["compilations"], "record.shaders.compilations")
    _metric(shaders["pipelineCreations"], "record.shaders.pipelineCreations")
    for index, diagnostic in enumerate(
        _array(shaders["diagnostics"], "record.shaders.diagnostics")
    ):
        path = f"record.shaders.diagnostics[{index}]"
        _object(diagnostic, path, {"severity", "code", "message"}, {"artifact"})
        if diagnostic["severity"] not in {"info", "warning", "error"}:
            raise ContractError(f"{path}.severity is invalid")
        _string(diagnostic["code"], f"{path}.code", token=True)
        _string(diagnostic["message"], f"{path}.message")
        if "artifact" in diagnostic and diagnostic["artifact"] not in artifacts:
            raise ContractError(f"{path} references an unknown artifact")


def _validate_lifecycle_process_manifest(
    process_manifest, run, build, *, ownership_required=False
):
    roles = set()
    for index, process in enumerate(
        _array(process_manifest, "record.lifecycle.processManifest", minimum=1)
    ):
        path = f"record.lifecycle.processManifest[{index}]"
        required = {"role", "executableSha256", "parentRole"}
        if ownership_required:
            required.add("ownedByRun")
        _object(process, path, required)
        role = _string(process["role"], f"{path}.role", token=True)
        if role in roles:
            raise ContractError(f"duplicate process role: {role}")
        roles.add(role)
        _hash(process["executableSha256"], f"{path}.executableSha256")
        parent = process["parentRole"]
        if parent is not None:
            _string(parent, f"{path}.parentRole", token=True)
        if ownership_required and not _boolean(
            process["ownedByRun"], f"{path}.ownedByRun"
        ):
            raise ContractError(f"{path} must be owned by the lifecycle run")
    for process in process_manifest:
        parent = process["parentRole"]
        if parent is not None and parent not in roles:
            raise ContractError(f"unknown parent process role: {parent}")
    by_role = {process["role"]: process for process in process_manifest}
    roots = [process for process in by_role.values() if process["parentRole"] is None]
    if len(roots) != 1 or roots[0]["role"] != "candidate":
        raise ContractError("process manifest requires exactly one candidate root")
    if roots[0]["executableSha256"] != run["binarySha256"]:
        raise ContractError("candidate process hash contradicts run binary hash")
    if roots[0]["executableSha256"] != build["binarySha256"]:
        raise ContractError("candidate process hash contradicts build binary hash")
    for role in by_role:
        visited = set()
        current = role
        while current != "candidate":
            if current in visited:
                raise ContractError("process manifest contains a cycle")
            visited.add(current)
            parent = by_role[current]["parentRole"]
            if parent is None:
                raise ContractError("process manifest contains an unreachable node")
            if parent == current:
                raise ContractError("process manifest contains a self-parent")
            current = parent


def _validate_lifecycle_v1(lifecycle, artifacts, run, build):
    _object(
        lifecycle,
        "record.lifecycle",
        {"processManifest", "iterations", "resources", "leakEvidence", "artifacts"},
    )
    _validate_lifecycle_process_manifest(
        lifecycle["processManifest"], run, build
    )

    iterations = _object(
        lifecycle["iterations"],
        "record.lifecycle.iterations",
        {"createDestroy", "reload", "deviceLoss"},
    )
    for field in iterations:
        _metric(iterations[field], f"record.lifecycle.iterations.{field}", positive=True)

    resources = _object(
        lifecycle["resources"],
        "record.lifecycle.resources",
        {"rssBytes", "threads", "fileDescriptors"},
        {"gpuResources"},
    )
    for resource_name, resource in resources.items():
        path = f"record.lifecycle.resources.{resource_name}"
        _object(resource, path, {"before", "after", "peak"})
        before = _metric(resource["before"], f"{path}.before")
        after = _metric(resource["after"], f"{path}.after")
        peak = _metric(resource["peak"], f"{path}.peak")
        if peak < max(before, after):
            raise ContractError(f"{path}.peak is below an endpoint")

    leaks = _object(
        lifecycle["leakEvidence"],
        "record.lifecycle.leakEvidence",
        {"tool", "status", "artifact"},
    )
    _string(leaks["tool"], "record.lifecycle.leakEvidence.tool")
    if leaks["status"] == "unavailable":
        raise ContractError("record.lifecycle.leakEvidence is required but unavailable")
    if leaks["status"] not in {"clean", "leaks"}:
        raise ContractError("record.lifecycle.leakEvidence.status is invalid")
    if leaks["artifact"] not in artifacts:
        raise ContractError("record.lifecycle.leakEvidence references an unknown artifact")
    _artifact_references(lifecycle["artifacts"], "record.lifecycle.artifacts", artifacts)


def _lifecycle_capability(value, path, *, positive=False, unavailable=False):
    _object(value, path, {"status"}, {"value", "reason"})
    if value["status"] == "unavailable":
        if not unavailable or set(value) != {"status", "reason"}:
            raise ContractError(f"{path} cannot be unavailable")
        _string(value["reason"], f"{path}.reason")
        return None
    if value["status"] != "available" or set(value) != {"status", "value"}:
        raise ContractError(f"{path} must be available or explicitly unavailable")
    return _integer(value["value"], f"{path}.value", positive=positive)


def _lifecycle_resource_sample(value, path, *, unavailable=False):
    if not isinstance(value, dict) or "status" not in value:
        raise ContractError(f"{path} must be a lifecycle resource sample")
    if value["status"] == "unavailable":
        if not unavailable:
            raise ContractError(f"{path} is required but unavailable")
        _object(value, path, {"status", "reason"})
        _string(value["reason"], f"{path}.reason")
        return None
    _object(value, path, {"status", "before", "after", "peak"})
    if value["status"] != "available":
        raise ContractError(f"{path}.status is invalid")
    before = _integer(value["before"], f"{path}.before")
    after = _integer(value["after"], f"{path}.after")
    peak = _integer(value["peak"], f"{path}.peak")
    if peak < max(before, after):
        raise ContractError(f"{path}.peak is below an endpoint")
    return before, after, peak


def _validate_lifecycle_v2(lifecycle, artifacts, run, build):
    _object(
        lifecycle,
        "record.lifecycle",
        {"processManifest", "iterations", "resources", "leakEvidence", "artifacts"},
    )
    _validate_lifecycle_process_manifest(
        lifecycle["processManifest"], run, build, ownership_required=True
    )
    iterations = _object(
        lifecycle["iterations"],
        "record.lifecycle.iterations",
        {"createDestroy", "reload", "deviceLoss"},
    )
    _lifecycle_capability(
        iterations["createDestroy"],
        "record.lifecycle.iterations.createDestroy",
        positive=True,
    )
    _lifecycle_capability(
        iterations["reload"], "record.lifecycle.iterations.reload", positive=True
    )
    _lifecycle_capability(
        iterations["deviceLoss"],
        "record.lifecycle.iterations.deviceLoss",
        positive=True,
        unavailable=True,
    )
    resources = _object(
        lifecycle["resources"],
        "record.lifecycle.resources",
        {
            "processes",
            "childProcesses",
            "rssBytes",
            "threads",
            "fileDescriptors",
            "trackedPrograms",
            "trackedRendererAllocations",
            "driverGpuResources",
        },
    )
    for name in (
        "processes", "childProcesses", "rssBytes", "threads", "fileDescriptors"
    ):
        _lifecycle_resource_sample(
            resources[name], f"record.lifecycle.resources.{name}"
        )
    for name in ("trackedPrograms", "trackedRendererAllocations"):
        _lifecycle_resource_sample(
            resources[name], f"record.lifecycle.resources.{name}"
        )
    driver_resources = _lifecycle_resource_sample(
        resources["driverGpuResources"],
        "record.lifecycle.resources.driverGpuResources",
        unavailable=True,
    )
    if driver_resources is not None:
        raise ContractError(
            "record.lifecycle.resources.driverGpuResources is reserved as unavailable"
        )
    leaks = _object(
        lifecycle["leakEvidence"],
        "record.lifecycle.leakEvidence",
        {"tool", "status", "artifact"},
    )
    tool = _object(
        leaks["tool"],
        "record.lifecycle.leakEvidence.tool",
        {"identity", "version", "executableSha256", "artifact"},
    )
    _string(tool["identity"], "record.lifecycle.leakEvidence.tool.identity", token=True)
    _string(tool["version"], "record.lifecycle.leakEvidence.tool.version")
    _hash(
        tool["executableSha256"],
        "record.lifecycle.leakEvidence.tool.executableSha256",
    )
    tool_artifact = _string(
        tool["artifact"], "record.lifecycle.leakEvidence.tool.artifact", token=True
    )
    if tool_artifact not in artifacts:
        raise ContractError("record.lifecycle.leakEvidence.tool artifact is unknown")
    if artifacts[tool_artifact]["sha256"] != tool["executableSha256"]:
        raise ContractError(
            "record.lifecycle.leakEvidence.tool hash contradicts its artifact"
        )
    if leaks["status"] not in {"clean", "leaks"}:
        raise ContractError("record.lifecycle.leakEvidence.status is invalid")
    if leaks["artifact"] not in artifacts:
        raise ContractError("record.lifecycle.leakEvidence references an unknown artifact")
    _artifact_references(lifecycle["artifacts"], "record.lifecycle.artifacts", artifacts)


def _validate_verdict(verdict, purpose, criteria_version, record):
    expected_checks = {
        "correctness": {"build", "correctness", "diagnostics"},
        "lifecycle": {"build", "lifecycle", "resources", "leaks"},
        "profiling": {"build", "validity", "quiescence"},
    }[purpose]
    _object(verdict, "record.verdict", {"accepted", "criteriaVersion", "checks", "failures"})
    accepted = _boolean(verdict["accepted"], "record.verdict.accepted")
    if verdict["criteriaVersion"] != criteria_version:
        raise ContractError("verdict criteria version contradicts the record")
    checks = _object(verdict["checks"], "record.verdict.checks", expected_checks)
    check_values = []
    for name in sorted(expected_checks):
        check_values.append(_boolean(checks[name], f"record.verdict.checks.{name}"))
    failures = _array(verdict["failures"], "record.verdict.failures")
    for index, failure in enumerate(failures):
        _string(failure, f"record.verdict.failures[{index}]")
    if accepted != (all(check_values) and not failures):
        raise ContractError("record verdict contradicts checks or failures")
    if checks["build"] is not True:
        raise ContractError("build check contradicts validated build evidence")
    if purpose == "correctness":
        assertions = (
            record["correctness"]["checkpoints"]
            + record["correctness"]["semanticAssertions"]
        )
        correctness_passed = (
            all(item["passed"] for item in assertions)
            and record["correctness"]["graphicsErrors"]["value"] == 0
        )
        diagnostics_passed = not any(
            item["severity"] == "error" for item in record["shaders"]["diagnostics"]
        )
        if checks["correctness"] != correctness_passed:
            raise ContractError("correctness check contradicts correctness evidence")
        if checks["diagnostics"] != diagnostics_passed:
            raise ContractError("diagnostics check contradicts shader evidence")
    if purpose == "lifecycle":
        leaks_passed = record["lifecycle"]["leakEvidence"]["status"] == "clean"
        if checks["leaks"] != leaks_passed:
            raise ContractError("leaks check contradicts leak evidence")
        if record["schemaVersion"] == 1 and checks["lifecycle"] is not True:
            raise ContractError("lifecycle check contradicts completed iterations")
    if purpose == "profiling":
        profile = record["profile"]
        if checks["validity"] != profile["validity"]:
            raise ContractError("validity check contradicts profile validity")
        manifest = profile["quiescenceManifest"]
        quiescence_clean = (
            manifest["ownershipClean"] and manifest["strayProcessCount"] == 0
        )
        if checks["quiescence"] != quiescence_clean:
            raise ContractError("quiescence check contradicts the quiescence manifest")


def _referenced_artifact_names(record, purpose):
    referenced = set(record["build"]["artifacts"])
    if purpose == "correctness":
        referenced.update(record["correctness"]["artifacts"])
        referenced.update(
            item["artifact"] for item in record["correctness"]["checkpoints"]
        )
        referenced.update(
            item["artifact"]
            for item in record["correctness"]["semanticAssertions"]
        )
        referenced.update(
            item["artifact"]
            for item in record["shaders"]["diagnostics"]
            if "artifact" in item
        )
        for item in record["correctness"].get("generatedArtifacts", []):
            referenced.update(
                {
                    item["artifact"],
                    item["comparisonArtifact"],
                    item["generatorBinaryArtifact"],
                }
            )
    if purpose == "lifecycle":
        referenced.update(record["lifecycle"]["artifacts"])
        referenced.add(record["lifecycle"]["leakEvidence"]["artifact"])
        tool = record["lifecycle"]["leakEvidence"]["tool"]
        if isinstance(tool, dict) and "artifact" in tool:
            referenced.add(tool["artifact"])
    if purpose == "profiling":
        referenced.update(record["profile"]["rawArtifacts"])
    return referenced


def _reject_persisted_paths(value, path="record"):
    if isinstance(value, dict):
        for key, child in value.items():
            _reject_persisted_paths(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _reject_persisted_paths(child, f"{path}[{index}]")
    elif isinstance(value, str) and PRIVATE_PATH_PATTERN.search(value):
        raise ContractError(f"{path} contains an absolute or user path")


def validate_result(record, artifact_root=None):
    if not isinstance(record, dict):
        raise ContractError("record must be an object")
    purpose = record.get("run", {}).get("purpose") if isinstance(record.get("run"), dict) else None
    common = {
        "schemaVersion",
        "run",
        "candidate",
        "criteriaVersion",
        "build",
        "artifacts",
        "verdict",
    }
    purpose_fields = {
        "correctness": {"host", "display", "policy", "correctness", "execution", "shaders"},
        "lifecycle": {"lifecycle"},
        "profiling": {"host", "display", "policy", "profile"},
    }
    if purpose not in PURPOSES:
        raise ContractError("record purpose is missing or unknown")
    _object(record, "record", common | purpose_fields[purpose])
    if record["schemaVersion"] not in RESULT_VERSIONS:
        raise ContractError("unsupported result record version")
    if record["schemaVersion"] == 2 and purpose != "lifecycle":
        raise ContractError("result record version 2 is lifecycle-only")
    if record["schemaVersion"] == 3 and purpose != "profiling":
        raise ContractError("result record version 3 is profiling-only")
    if purpose == "profiling" and record["schemaVersion"] != 3:
        raise ContractError("profiling records require result version 3")
    _validate_run(record["run"])
    _validate_candidate(record["candidate"])
    criteria_version = _string(record["criteriaVersion"], "record.criteriaVersion", token=True)
    artifacts = _validate_artifacts(record["artifacts"])
    _validate_build(record["build"], record["run"], artifacts)
    if purpose == "correctness":
        _validate_host_display_policy(record)
        _validate_correctness(record["correctness"], artifacts, record["run"])
        _validate_execution(record["execution"])
        _validate_shaders(record["shaders"], artifacts)
    if purpose == "lifecycle":
        validator = (
            _validate_lifecycle_v2
            if record["schemaVersion"] == 2
            else _validate_lifecycle_v1
        )
        validator(record["lifecycle"], artifacts, record["run"], record["build"])
    if purpose == "profiling":
        _validate_host_display_policy(record)
        _validate_profile(record["profile"], artifacts, record["run"])
    _validate_verdict(record["verdict"], purpose, criteria_version, record)
    unreferenced = set(artifacts) - _referenced_artifact_names(record, purpose)
    if unreferenced:
        raise ContractError(
            "record contains unreferenced artifacts: "
            + ", ".join(sorted(unreferenced))
        )
    _reject_persisted_paths(record)
    if artifact_root is not None:
        verify_artifacts(record, artifact_root)
    return record


def validate_result_against_manifest(record, workload_manifest, artifact_root=None):
    validate_manifest(workload_manifest)
    validate_result(record, artifact_root=artifact_root)
    run = record["run"]
    expected_workload = {
        "identity": workload_manifest["workload"]["identity"],
        "version": workload_manifest["workload"]["version"],
    }
    comparisons = (
        (run["workload"], expected_workload, "workload identity"),
        (run["manifestSha256"], manifest_hash(workload_manifest), "manifest hash"),
        (run["assets"], workload_manifest["assets"], "asset hashes"),
        (run["inputs"], workload_manifest["inputs"], "input hashes"),
        (run["seed"], workload_manifest["seed"], "seed"),
        (
            record["criteriaVersion"],
            workload_manifest["criteriaVersion"],
            "criteria version",
        ),
    )
    for actual, expected, name in comparisons:
        if actual != expected:
            raise ContractError(f"result contradicts workload manifest {name}")
    if record["run"]["purpose"] == "correctness":
        correctness = record["correctness"]
        if correctness["reference"] != workload_manifest["reference"]:
            raise ContractError("result contradicts workload manifest reference")
        expected_checkpoints = [
            {
                "identity": item["identity"],
                "invariants": item["invariants"],
            }
            for item in workload_manifest["checkpoints"]
        ]
        actual_checkpoints = [
            {
                "identity": item["identity"],
                "invariants": item["invariants"],
            }
            for item in correctness["checkpoints"]
        ]
        if actual_checkpoints != expected_checkpoints:
            raise ContractError(
                "result checkpoint identities or invariant associations contradict manifest"
            )
        expected_assertions = [
            item["identity"] for item in workload_manifest["invariants"]
        ]
        actual_assertions = [
            item["identity"] for item in correctness["semanticAssertions"]
        ]
        if actual_assertions != expected_assertions:
            raise ContractError("result semantic assertions contradict manifest invariants")
        expected_generated = workload_manifest.get("derivedArtifacts", [])
        actual_generated = [
            {
                field: item[field]
                for field in DERIVED_ARTIFACT_RELATIONSHIP_FIELDS
            }
            for item in correctness.get("generatedArtifacts", [])
        ]
        if actual_generated != expected_generated:
            raise ContractError(
                "result generated artifact relationships contradict manifest"
            )
    if record["run"]["purpose"] == "lifecycle" and record["schemaVersion"] == 2:
        _validate_lifecycle_against_manifest(
            record, workload_manifest, artifact_root
        )
    return record


def _artifact_by_name(record, name):
    for artifact in record["artifacts"]:
        if artifact["name"] == name:
            return artifact
    raise ContractError(f"record references unknown artifact {name}")


def _load_json_artifact(record, name, artifact_root):
    if artifact_root is None:
        raise ContractError(
            "lifecycle version 2 manifest validation requires artifact evidence"
        )
    artifact = _artifact_by_name(record, name)
    path = pathlib.Path(artifact_root) / artifact["path"]
    try:
        return load_json(path)
    except (OSError, json.JSONDecodeError) as error:
        raise ContractError(f"lifecycle artifact {name} is not valid JSON") from error


def _require_equal(actual, expected, description):
    if actual != expected:
        raise ContractError(f"lifecycle evidence contradicts {description}")


def _raw_leak_count(report, path):
    if not isinstance(report, dict):
        raise ContractError(f"{path} must be an object")
    leak_count = _integer(report.get("leakCount"), f"{path}.leakCount")
    leaked_bytes = _integer(report.get("leakedBytes"), f"{path}.leakedBytes")
    stdout = _string(report.get("stdout"), f"{path}.stdout")
    summary = re.search(
        r"Process [0-9]+: ([0-9]+) leaks for ([0-9]+) total leaked bytes\.",
        stdout,
    )
    if summary is None:
        raise ContractError(f"{path}.stdout has no raw leak summary")
    _require_equal(leak_count, int(summary.group(1)), f"{path} leak count")
    _require_equal(leaked_bytes, int(summary.group(2)), f"{path} leaked bytes")
    _require_equal(report.get("clean"), leak_count == 0, f"{path} clean status")
    return leak_count


LIFECYCLE_V2_ALLOWED_SIGNATURES = [
    {"identity": "apple-appintents", "stackToken": "AppIntents"},
    {"identity": "apple-linkservices", "stackToken": "LinkServices"},
    {"identity": "apple-nsxpcconnection", "stackToken": "NSXPCConnection"},
]
LIFECYCLE_V2_FORBIDDEN_TOKENS = [
    "FrescoScene", "fresco-scene", "WallpaperEngine", "OpenGL",
    "libGLES", "libEGL", "ANGLE", "Metal.framework", "AGXMetal", "MTL",
]
LIFECYCLE_LEAK_STACK_HEADING = re.compile(
    r"(?m)^STACK OF ([0-9]+) INSTANCES? OF .+$"
)


def _lifecycle_v2_leak_criteria(reference):
    criteria = _object(
        reference["leakCriteria"], "lifecycle reference.leakCriteria",
        {
            "normalizationVersion", "controlProtocol",
            "allowedNormalizedSignatures", "forbiddenAttributionTokens",
            "requiredControlSignatureRelation",
            "requiredSubjectSignatureRelation",
            "requiredSubjectTotalsRelation", "maximumUnknownGroups",
            "maximumForbiddenAttributionGroups",
            "maximumSubjectOnlySignatures",
        },
    )
    _require_equal(
        criteria["normalizationVersion"],
        "apple-framework-matched-control-v1", "normalization version",
    )
    _require_equal(
        criteria["controlProtocol"],
        {
            "assignment": "lifecycle-appkit-window-control",
            "eventTypes": ["hello", "ready", "stopped"], "loads": 1,
        },
        "matched control protocol",
    )
    _require_equal(
        criteria["allowedNormalizedSignatures"],
        LIFECYCLE_V2_ALLOWED_SIGNATURES, "allowed normalized signatures",
    )
    _require_equal(
        criteria["forbiddenAttributionTokens"],
        LIFECYCLE_V2_FORBIDDEN_TOKENS, "forbidden attribution tokens",
    )
    _require_equal(
        criteria["requiredControlSignatureRelation"], "exact-allowed-set",
        "control signature relation",
    )
    _require_equal(
        criteria["requiredSubjectSignatureRelation"], "subset-of-control",
        "subject signature relation",
    )
    _require_equal(
        criteria["requiredSubjectTotalsRelation"],
        "objects-and-bytes-not-greater-than-control", "subject totals relation",
    )
    for name in (
        "maximumUnknownGroups", "maximumForbiddenAttributionGroups",
        "maximumSubjectOnlySignatures",
    ):
        _require_equal(criteria[name], 0, name)
    return criteria


def _derived_normalized_leak_evidence(report, criteria, path):
    stdout = report["stdout"]
    matches = list(LIFECYCLE_LEAK_STACK_HEADING.finditer(stdout))
    if report["leakCount"] > 0 and not matches:
        raise ContractError(f"{path} has no complete STACK OF evidence")
    groups = []
    for index, match in enumerate(matches):
        next_heading = (
            matches[index + 1].start()
            if index + 1 < len(matches) else len(stdout)
        )
        delimiter = re.search(
            r"(?m)^====\s*$", stdout[match.end():next_heading]
        )
        if delimiter is None:
            raise ContractError(f"{path} STACK OF evidence has no closing delimiter")
        end = match.end() + delimiter.end()
        stack = stdout[match.start():end].rstrip() + "\n"
        signatures = sorted(
            item["identity"]
            for item in criteria["allowedNormalizedSignatures"]
            if item["stackToken"] in stack
        )
        forbidden = sorted(
            token for token in criteria["forbiddenAttributionTokens"]
            if token in stack
        )
        groups.append({
            "instanceCount": int(match.group(1)),
            "stackSha256": hashlib.sha256(stack.encode("utf-8")).hexdigest(),
            "signatures": signatures,
            "forbiddenAttributionTokens": forbidden,
        })
    return {
        "normalizationVersion": criteria["normalizationVersion"],
        "groups": groups,
        "normalizedSignatures": sorted({
            signature for group in groups for signature in group["signatures"]
        }),
        "unknownGroupCount": sum(not group["signatures"] for group in groups),
        "forbiddenAttributionGroupCount": sum(
            bool(group["forbiddenAttributionTokens"]) for group in groups
        ),
    }


def _validate_lifecycle_v2_leak_report(report, criteria, path):
    _object(
        report, path,
        {
            "assignment", "loadCount", "commands", "exitStatus", "clean",
            "leakCount", "leakedBytes", "eventTypes", "stoppedLifecycle",
            "stdout", "stderr", "normalization",
        },
    )
    _raw_leak_count(report, path)
    derived = _derived_normalized_leak_evidence(report, criteria, path)
    _require_equal(report["normalization"], derived, f"{path} normalization")
    return derived


def _validate_lifecycle_against_manifest(record, workload_manifest, artifact_root):
    lifecycle = record["lifecycle"]
    reference_artifacts = [
        artifact for artifact in record["artifacts"]
        if artifact["sha256"] == workload_manifest["reference"]["sha256"]
        and artifact["bytes"] == workload_manifest["reference"]["bytes"]
    ]
    if len(reference_artifacts) != 1:
        raise ContractError("lifecycle record does not bind exactly one manifest reference")
    reference_artifact = reference_artifacts[0]
    if reference_artifact["name"] not in lifecycle["artifacts"]:
        raise ContractError("lifecycle manifest reference is not a lifecycle artifact")
    reference = _load_json_artifact(
        record, reference_artifact["name"], artifact_root
    )
    reference_version = reference.get("schemaVersion")
    reference_keys = {
        "schemaVersion", "workload", "profile", "required",
        "resourceCriteria", "deviceLoss", "driverGpuResources",
        "metricDefinitions",
    }
    if reference_version == 2:
        reference_keys.add("leakCriteria")
    _object(reference, "lifecycle reference", reference_keys)
    if (
        reference_version not in {1, 2}
        or reference["profile"]
            != ("lifecycle" if reference_version == 1 else "lifecycle-matched-control")
    ):
        raise ContractError("unsupported lifecycle reference profile")
    _require_equal(
        reference["workload"], workload_manifest["workload"]["identity"],
        "manifest workload",
    )
    required_keys = {
        "createDestroyIterations", "reloadIterations",
        "generationsPerIteration", "completionBarriersPerIteration",
        "liveGenerationsAfterStop", "programPublicationDeletionBalance",
        "ownedProcessesAfterStop",
    }
    if reference_version == 1:
        required_keys.add("atExitLeakCount")
    required = _object(
        reference["required"], "lifecycle reference.required", required_keys
    )
    for name in required:
        if name == "programPublicationDeletionBalance":
            _boolean(required[name], f"lifecycle reference.required.{name}")
        else:
            _integer(required[name], f"lifecycle reference.required.{name}")
    expected_iterations = {
        "createDestroy": {"status": "available", "value": required["createDestroyIterations"]},
        "reload": {"status": "available", "value": required["reloadIterations"]},
        "deviceLoss": reference["deviceLoss"],
    }
    _require_equal(lifecycle["iterations"], expected_iterations, "predeclared iterations")
    resources = lifecycle["resources"]
    criteria = _object(
        reference["resourceCriteria"], "lifecycle reference.resourceCriteria",
        {
            "processes", "childProcesses", "rssBytes", "threads",
            "fileDescriptors", "trackedPrograms",
            "trackedRendererAllocations",
        },
    )
    resources_passed = True
    for name, criterion in criteria.items():
        _object(
            criterion, f"lifecycle reference.resourceCriteria.{name}",
            {"before", "after", "peakAtLeast"},
        )
        for field in criterion:
            _integer(criterion[field], f"lifecycle reference.resourceCriteria.{name}.{field}")
        sample = resources[name]
        passed = (
            sample["status"] == "available"
            and sample["before"] == criterion["before"]
            and sample["after"] == criterion["after"]
            and sample["peak"] >= criterion["peakAtLeast"]
        )
        resources_passed = resources_passed and passed
    _require_equal(
        resources["driverGpuResources"], reference["driverGpuResources"],
        "driver GPU availability",
    )
    evidence = _load_json_artifact(
        record, lifecycle["leakEvidence"]["artifact"], artifact_root
    )
    _object(
        evidence, "lifecycle raw evidence",
        {
            "schemaVersion", "auditor", "iterations", "atExitLeakReport",
            "matchedAppKitControl", "resourcePeaks", "deviceLoss",
        },
    )
    expected_evidence_version = 2 if reference_version == 1 else 3
    if evidence["schemaVersion"] != expected_evidence_version:
        raise ContractError("unsupported lifecycle raw evidence version")
    _require_equal(evidence["deviceLoss"], reference["deviceLoss"], "device-loss capability")
    iterations = _array(
        evidence["iterations"], "lifecycle raw evidence.iterations",
        minimum=required["createDestroyIterations"],
    )
    _require_equal(
        len(iterations), required["createDestroyIterations"],
        "create/destroy iteration count",
    )
    lifecycle_passed = True
    derived_peaks = {
        "processes": 0, "childProcesses": 0, "rssBytes": 0,
        "threads": 0, "fileDescriptors": 0, "trackedPrograms": 0,
        "trackedRendererAllocations": 0,
    }
    for index, iteration in enumerate(iterations, 1):
        _require_equal(iteration.get("iteration"), index, "iteration sequence")
        snapshots = _array(
            iteration.get("snapshots"),
            f"lifecycle raw evidence.iterations[{index - 1}].snapshots",
            minimum=1,
        )
        for snapshot in snapshots:
            totals = snapshot.get("totals", {})
            for name in ("processes", "childProcesses", "rssBytes", "threads", "fileDescriptors"):
                amount = _integer(
                    totals.get(name),
                    f"lifecycle raw evidence.iterations[{index - 1}].totals.{name}",
                )
                derived_peaks[name] = max(derived_peaks[name], amount)
        first = iteration.get("firstLoad", {})
        reload = iteration.get("reload", {})
        for event in (first, reload):
            derived_peaks["trackedPrograms"] = max(
                derived_peaks["trackedPrograms"],
                _integer(event.get("programCacheEntries"), "lifecycle program entries"),
            )
            derived_peaks["trackedRendererAllocations"] = max(
                derived_peaks["trackedRendererAllocations"],
                _integer(event.get("liveRendererAllocations"), "lifecycle renderer allocations"),
            )
        stopped = iteration.get("stoppedLifecycle", {})
        if not isinstance(stopped, dict):
            raise ContractError("lifecycle stopped evidence must be an object")
        owned_after = _array(
            iteration.get("ownedProcessesAfterStop"),
            "lifecycle owned processes after stop",
        )
        iteration_passed = (
            stopped.get("generationsCreated") == required["generationsPerIteration"]
            and stopped.get("generationsRetired") == required["generationsPerIteration"]
            and stopped.get("liveGenerations") == required["liveGenerationsAfterStop"]
            and stopped.get("completionBarriersCompleted") == required["completionBarriersPerIteration"]
            and stopped.get("completionBarriersFailed") == 0
            and stopped.get("retirementsWithoutCompletion") == 0
            and len(owned_after) == required["ownedProcessesAfterStop"]
        )
        if required["programPublicationDeletionBalance"]:
            iteration_passed = iteration_passed and (
                stopped.get("programPublications") == stopped.get("programDeletions")
            )
        lifecycle_passed = lifecycle_passed and iteration_passed
    _require_equal(evidence["resourcePeaks"], derived_peaks, "derived resource peaks")
    for name, peak in derived_peaks.items():
        _require_equal(resources[name]["peak"], peak, f"{name} peak evidence")
    leak_report = evidence["atExitLeakReport"]
    control = evidence["matchedAppKitControl"]
    if reference_version == 1:
        leak_count = _raw_leak_count(
            leak_report, "lifecycle at-exit leak report"
        )
        _raw_leak_count(control, "lifecycle matched AppKit control")
        _require_equal(
            control.get("eventTypes"), ["hello", "ready", "stopped"],
            "matched AppKit control sequence",
        )
        leaks_passed = leak_count == required["atExitLeakCount"]
    else:
        criteria = _lifecycle_v2_leak_criteria(reference)
        subject_normalization = _validate_lifecycle_v2_leak_report(
            leak_report, criteria, "lifecycle at-exit leak report"
        )
        control_normalization = _validate_lifecycle_v2_leak_report(
            control, criteria, "lifecycle matched AppKit control"
        )
        protocol = criteria["controlProtocol"]
        _require_equal(control["assignment"], protocol["assignment"], "matched control assignment")
        _require_equal(control["eventTypes"], protocol["eventTypes"], "matched control sequence")
        _require_equal(control["loadCount"], protocol["loads"], "matched control load count")
        allowed = sorted(
            item["identity"] for item in criteria["allowedNormalizedSignatures"]
        )
        control_signatures = set(control_normalization["normalizedSignatures"])
        subject_signatures = set(subject_normalization["normalizedSignatures"])
        leaks_passed = (
            sorted(control_signatures) == allowed
            and subject_signatures <= control_signatures
            and len(subject_signatures - control_signatures)
                <= criteria["maximumSubjectOnlySignatures"]
            and subject_normalization["unknownGroupCount"]
                <= criteria["maximumUnknownGroups"]
            and subject_normalization["forbiddenAttributionGroupCount"]
                <= criteria["maximumForbiddenAttributionGroups"]
            and control_normalization["unknownGroupCount"]
                <= criteria["maximumUnknownGroups"]
            and control_normalization["forbiddenAttributionGroupCount"]
                <= criteria["maximumForbiddenAttributionGroups"]
            and leak_report["leakCount"] <= control["leakCount"]
            and leak_report["leakedBytes"] <= control["leakedBytes"]
        )
    leak_status = "clean" if leaks_passed else "leaks"
    _require_equal(
        lifecycle["leakEvidence"]["status"], leak_status, "raw leak evidence"
    )
    checks = record["verdict"]["checks"]
    _require_equal(checks["lifecycle"], lifecycle_passed, "lifecycle verdict")
    _require_equal(checks["resources"], resources_passed, "resource verdict")


DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW


@contextlib.contextmanager
def _owned_descriptor(descriptor):
    try:
        yield descriptor
    finally:
        os.close(descriptor)


def _open_absolute_directory(path):
    absolute = pathlib.Path(os.path.abspath(os.fspath(path)))
    descriptor = os.open("/", DIRECTORY_FLAGS)
    try:
        for component in absolute.parts[1:]:
            next_descriptor = os.open(
                component, DIRECTORY_FLAGS, dir_fd=descriptor
            )
            try:
                os.close(descriptor)
            except Exception:
                os.close(next_descriptor)
                raise
            descriptor = next_descriptor
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def _open_source(path):
    path = pathlib.Path(os.path.abspath(os.fspath(path)))
    if path.name in {"", ".", ".."}:
        raise ContractError("artifact source must name a file")
    descriptor = None
    try:
        with _owned_descriptor(_open_absolute_directory(path.parent)) as parent:
            descriptor = os.open(path.name, READ_FLAGS, dir_fd=parent)
    except OSError as error:
        if descriptor is not None:
            os.close(descriptor)
        raise ContractError("artifact source path is missing or unsafe") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ContractError("artifact source must be a regular file")
    except Exception:
        os.close(descriptor)
        raise
    return descriptor


def _open_store_root(root):
    try:
        return _open_absolute_directory(root)
    except OSError as error:
        raise ContractError("artifact store path is missing or unsafe") from error


def _open_or_create_directory(parent_descriptor, name):
    try:
        os.mkdir(name, dir_fd=parent_descriptor)
    except FileExistsError:
        pass
    try:
        return os.open(name, DIRECTORY_FLAGS, dir_fd=parent_descriptor)
    except OSError as error:
        raise ContractError(f"artifact store directory is unsafe: {name}") from error


def _write_all(descriptor, value):
    offset = 0
    while offset < len(value):
        written = os.write(descriptor, value[offset:])
        if written <= 0:
            raise OSError("short artifact write")
        offset += written


def _descriptor_digest(descriptor):
    digest = hashlib.sha256()
    byte_count = 0
    os.lseek(descriptor, 0, os.SEEK_SET)
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
        byte_count += len(chunk)
    return digest.hexdigest(), byte_count


def _metadata_identity(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _open_cas_artifact(root_descriptor, digest):
    descriptor = None
    try:
        with _owned_descriptor(
            os.open("artifacts", DIRECTORY_FLAGS, dir_fd=root_descriptor)
        ) as artifacts:
            with _owned_descriptor(
                os.open("sha256", DIRECTORY_FLAGS, dir_fd=artifacts)
            ) as sha_directory:
                with _owned_descriptor(
                    os.open(digest[:2], DIRECTORY_FLAGS, dir_fd=sha_directory)
                ) as prefix:
                    descriptor = os.open(digest, READ_FLAGS, dir_fd=prefix)
    except Exception:
        if descriptor is not None:
            os.close(descriptor)
        raise
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ContractError("content-addressed artifact is not a regular file")
    except Exception:
        os.close(descriptor)
        raise
    return descriptor


def _verify_cas_artifact(root_descriptor, artifact):
    try:
        descriptor = _open_cas_artifact(root_descriptor, artifact["sha256"])
    except OSError as error:
        raise ContractError(
            f"artifact is missing or unsafe: {artifact['name']}"
        ) from error
    with _owned_descriptor(descriptor):
        digest, byte_count = _descriptor_digest(descriptor)
    if digest != artifact["sha256"] or byte_count != artifact["bytes"]:
        raise ContractError(f"artifact verification failed: {artifact['name']}")


def _publish_without_overwrite(
    temporary_name,
    temporary_directory,
    target_name,
    target_directory,
    expected_digest,
    expected_bytes,
):
    created = False
    try:
        try:
            os.link(
                temporary_name,
                target_name,
                src_dir_fd=temporary_directory,
                dst_dir_fd=target_directory,
                follow_symlinks=False,
            )
            created = True
        except FileExistsError:
            pass
        try:
            with _owned_descriptor(
                os.open(target_name, READ_FLAGS, dir_fd=target_directory)
            ) as descriptor:
                actual_digest, actual_bytes = _descriptor_digest(descriptor)
        except OSError as error:
            raise ContractError("content-addressed target is unsafe") from error
        if (actual_digest, actual_bytes) != (expected_digest, expected_bytes):
            if created:
                os.unlink(target_name, dir_fd=target_directory)
            raise ContractError("content-addressed target is corrupt")
        os.fsync(target_directory)
    finally:
        try:
            os.unlink(temporary_name, dir_fd=temporary_directory)
        except FileNotFoundError:
            pass


def _open_private_file(directory_descriptor, temporary_name):
    return os.open(
        temporary_name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
        dir_fd=directory_descriptor,
    )


def ingest_artifact(source, store_root, name, media_type, *, _test_hook=None):
    name = _string(name, "artifact.name", token=True)
    media_type = _string(media_type, "artifact.mediaType")
    with _owned_descriptor(_open_store_root(store_root)) as root_descriptor:
        with _owned_descriptor(_open_source(source)) as source_descriptor:
            before = os.fstat(source_descriptor)
            if _test_hook is not None:
                _test_hook()
            with _owned_descriptor(
                _open_or_create_directory(root_descriptor, "artifacts")
            ) as artifacts_descriptor:
                with _owned_descriptor(
                    _open_or_create_directory(artifacts_descriptor, "sha256")
                ) as sha_descriptor:
                    temporary_name = f".ingest-{secrets.token_hex(16)}"
                    temporary_created = False
                    try:
                        with _owned_descriptor(
                            _open_private_file(sha_descriptor, temporary_name)
                        ) as temporary_descriptor:
                            temporary_created = True
                            digest_state = hashlib.sha256()
                            byte_count = 0
                            os.lseek(source_descriptor, 0, os.SEEK_SET)
                            while True:
                                chunk = os.read(source_descriptor, 1024 * 1024)
                                if not chunk:
                                    break
                                digest_state.update(chunk)
                                byte_count += len(chunk)
                                _write_all(temporary_descriptor, chunk)
                            os.fsync(temporary_descriptor)
                            after = os.fstat(source_descriptor)
                            if _metadata_identity(before) != _metadata_identity(after):
                                raise ContractError(
                                    "artifact source changed during ingest"
                                )
                            if byte_count != after.st_size:
                                raise ContractError(
                                    "artifact source size changed during ingest"
                                )
                            digest = digest_state.hexdigest()
                        with _owned_descriptor(
                            _open_or_create_directory(sha_descriptor, digest[:2])
                        ) as prefix_descriptor:
                            _publish_without_overwrite(
                                temporary_name,
                                sha_descriptor,
                                digest,
                                prefix_descriptor,
                                digest,
                                byte_count,
                            )
                            with _owned_descriptor(
                                os.open(
                                    digest, READ_FLAGS, dir_fd=prefix_descriptor
                                )
                            ) as descriptor:
                                installed = _descriptor_digest(descriptor)
                            if installed != (digest, byte_count):
                                raise ContractError(
                                    "installed artifact does not match ingest digest"
                                )
                    finally:
                        if temporary_created:
                            try:
                                os.unlink(temporary_name, dir_fd=sha_descriptor)
                            except FileNotFoundError:
                                pass
    return {
        "name": name,
        "mediaType": media_type,
        "sha256": digest,
        "bytes": byte_count,
        "path": f"artifacts/sha256/{digest[:2]}/{digest}",
    }


def verify_artifacts(record, store_root):
    artifacts = _validate_artifacts(record["artifacts"])
    with _owned_descriptor(_open_store_root(store_root)) as root_descriptor:
        for artifact in artifacts.values():
            _verify_cas_artifact(root_descriptor, artifact)


def write_record(record, workload_manifest, store_root):
    validate_result_against_manifest(
        record, workload_manifest, artifact_root=store_root
    )
    payload = canonical_json_bytes(record)
    digest = hashlib.sha256(payload).hexdigest()
    root = pathlib.Path(os.path.abspath(os.fspath(store_root)))
    with _owned_descriptor(_open_store_root(root)) as root_descriptor:
        with _owned_descriptor(
            _open_or_create_directory(root_descriptor, "records")
        ) as records_descriptor:
            temporary_name = f".record-{secrets.token_hex(16)}"
            temporary_created = False
            try:
                with _owned_descriptor(
                    _open_private_file(records_descriptor, temporary_name)
                ) as temporary_descriptor:
                    temporary_created = True
                    _write_all(temporary_descriptor, payload)
                    os.fsync(temporary_descriptor)
                _publish_without_overwrite(
                    temporary_name,
                    records_descriptor,
                    f"{digest}.json",
                    records_descriptor,
                    digest,
                    len(payload),
                )
            finally:
                if temporary_created:
                    try:
                        os.unlink(temporary_name, dir_fd=records_descriptor)
                    except FileNotFoundError:
                        pass
    return root / "records" / f"{digest}.json"
