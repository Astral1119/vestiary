#!/usr/bin/env python3

import dataclasses
import datetime
import hashlib
import json
import os
import pathlib
import platform
import queue
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import typing

import contract


WORKLOAD_ROOT = pathlib.Path(__file__).with_name("workloads")
SUPPORTED_WORKLOADS = {
    "static-no-media", "continuous-animation", "script-heavy", "particle-heavy",
    "media-video", "audio-reactive", "masks-effects",
    "resource-reload",
}
BACKENDS = {
    "native-opengl": {
        "graphicsApi": "opengl-4.1-core",
        "shaderApi": "glsl-410-core",
        "observedGraphicsAPI": "OpenGL 4.1 core",
        "observedShaderTarget": {
            "language": "GLSL", "profile": "desktop-core", "version": 410,
        },
    },
    "angle-metal": {
        "graphicsApi": "opengl-es-3.0-angle-metal",
        "shaderApi": "glsl-es-300",
        "observedGraphicsAPI": "OpenGL ES 3.0 via ANGLE Metal",
        "observedShaderTarget": {
            "language": "GLSL", "profile": "embedded", "version": 300,
        },
    },
}
ASSET_FILES = {
    "project-json": "project.json",
    "scene-json": "scene.json",
    "timer-scene-json": "timer-scene.json",
    "particle-definition-json": "particles/finite.json",
    "particle-material-json": "materials/particle-fixture.json",
    "unknown-particle-scene-json": "unknown-scene.json",
    "unknown-particle-definition-json": "particles/unknown.json",
    "unknown-audio-scene-json": "unknown-scene.json",
    "near-match-audio-scene-json": "near-match-scene.json",
    "audio-model-json": "models/audio.json",
    "audio-material-json": "materials/audio.json",
    "media-model-json": "models/video.json",
    "media-material-json": "materials/video.json",
    "media-fixture-generator-source": "../../../../renderer/tests/media_fixture_generator.mm",
    "effect-model-json": "models/fixture.json",
    "effect-base-material-json": "materials/fixture.json",
    "effect-graph-json": "effects/ordered/effect.json",
    "effect-pass-a-material-json": "materials/effects/ordered-a.json",
    "effect-pass-b-material-json": "materials/effects/ordered-b.json",
    "effect-composite-material-json": "materials/effects/ordered-composite.json",
    "effect-pass-a-vertex-shader": "shaders/effects/fresco_ordered_a.vert",
    "effect-pass-b-vertex-shader": "shaders/effects/fresco_ordered_b.vert",
    "effect-composite-vertex-shader": "shaders/effects/fresco_ordered_composite.vert",
    "effect-pass-a-fragment-shader": "shaders/effects/fresco_ordered_a.frag",
    "effect-pass-b-fragment-shader": "shaders/effects/fresco_ordered_b.frag",
    "effect-composite-fragment-shader": "shaders/effects/fresco_ordered_composite.frag",
    "invalid-fragment-shader": "invalid.frag",
    "puppet-generator-source": "generate_puppet_fixture.py",
    "puppet-masked-scene-json": "puppet-masked-scene.json",
    "puppet-unmasked-scene-json": "puppet-unmasked-scene.json",
    "puppet-masked-model-json": "models/puppet-masked.json",
    "puppet-unmasked-model-json": "models/puppet-unmasked.json",
    "puppet-material-json": "materials/puppet.json",
    "puppet-masked-model-output": "generated-puppet/models/masked.mdl",
    "puppet-unmasked-model-output": "generated-puppet/models/unmasked.mdl",
    "puppet-base-texture-output": "generated-puppet/materials/base.tex",
    "puppet-mask-texture-output": "generated-puppet/materials/masks/mask.tex",
}
INPUT_FILES = {
    "trace-v1": "trace-v1.json",
    "media-generator-parameters-v1": "generator-parameters-v1.json",
    "puppet-generator-parameters-v1": "puppet-generator-parameters-v1.json",
}
REFERENCE_FILE = "reference-v1.json"
SCHEDULER_REASON_INDEX = {"lease-continuous": 6, "fps-ceiling": 8}
LEASE_AT_REASON_INDEX = 4


class AdapterError(RuntimeError):
    pass


@dataclasses.dataclass(frozen=True)
class CandidateConfiguration:
    helper_binary: pathlib.Path
    asset_root: pathlib.Path
    expected_candidate: str
    expected_backend: str
    store_root: pathlib.Path
    source_manifest: pathlib.Path
    source_sha256: str
    build_identity: str
    build_commands: tuple[str, ...]
    operator: str
    agent_role: str
    media_fixture_generator: typing.Optional[pathlib.Path] = None
    timeout_seconds: float = 30.0


def _physical_path(path, label, *, directory=False, executable=False):
    value = pathlib.Path(os.path.abspath(os.fspath(path)))
    if os.path.realpath(value) != os.fspath(value):
        raise AdapterError(f"{label} must be a physical path without symlinks")
    if directory and not value.is_dir():
        raise AdapterError(f"{label} must be a pre-existing directory")
    if not directory and not value.is_file():
        raise AdapterError(f"{label} must be a regular file")
    if executable and not os.access(value, os.X_OK):
        raise AdapterError(f"{label} must be executable")
    return value


def normalize_wrapper_path(path):
    return pathlib.Path(os.path.realpath(os.path.abspath(os.fspath(path))))


def _sha256_file(path):
    digest = hashlib.sha256()
    byte_count = 0
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
            byte_count += len(chunk)
    return digest.hexdigest(), byte_count


def _require(condition, message):
    if not condition:
        raise AdapterError(message)


def _available(value):
    return {"status": "available", "value": int(value)}


def _utc_now():
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .isoformat(timespec="microseconds")
        .replace("+00:00", "Z")
    )


def _validate_configuration(configuration):
    helper = _physical_path(
        configuration.helper_binary, "helper binary", executable=True
    )
    assets = _physical_path(configuration.asset_root, "asset root", directory=True)
    store = _physical_path(configuration.store_root, "store root", directory=True)
    source_manifest = _physical_path(
        configuration.source_manifest, "source manifest"
    )
    media_fixture_generator = None
    if configuration.media_fixture_generator is not None:
        media_fixture_generator = _physical_path(
            configuration.media_fixture_generator,
            "media fixture generator",
            executable=True,
        )
    if configuration.expected_backend not in BACKENDS:
        raise AdapterError("unsupported expected backend")
    contract._string(
        configuration.expected_candidate, "expected candidate", token=True
    )
    contract._hash(configuration.source_sha256, "source SHA-256")
    contract._string(configuration.build_identity, "build identity", token=True)
    contract._string(configuration.operator, "operator")
    if configuration.agent_role not in contract.ROLES:
        raise AdapterError("agent role is invalid")
    if not configuration.build_commands:
        raise AdapterError("at least one build command label is required")
    for command in configuration.build_commands:
        contract._string(command, "build command")
        if contract.PRIVATE_PATH_PATTERN.search(command):
            raise AdapterError("build command labels cannot contain private paths")
    if configuration.timeout_seconds <= 0:
        raise AdapterError("timeout must be positive")
    manifest_bytes = source_manifest.read_bytes()
    try:
        source_value = contract.load_json(source_manifest)
    except (OSError, ValueError) as error:
        raise AdapterError("source manifest is invalid") from error
    canonical = contract.canonical_json_bytes(source_value)
    if manifest_bytes != canonical:
        raise AdapterError("source manifest is not canonical JSON")
    if hashlib.sha256(canonical).hexdigest() != configuration.source_sha256:
        raise AdapterError("source manifest digest mismatch")
    try:
        contract._reject_persisted_paths(source_value, "source manifest")
    except contract.ContractError as error:
        raise AdapterError(str(error)) from error
    return dataclasses.replace(
        configuration,
        helper_binary=helper,
        asset_root=assets,
        store_root=store,
        source_manifest=source_manifest,
        media_fixture_generator=media_fixture_generator,
    )


def _load_workload(identity):
    if identity not in SUPPORTED_WORKLOADS:
        raise AdapterError(f"adapter workload is unsupported: {identity}")
    root = _physical_path(WORKLOAD_ROOT / identity, "workload root", directory=True)
    manifest = contract.load_json(root / "manifest-v1.json")
    contract.validate_manifest(manifest)
    if manifest["workload"]["identity"] != identity:
        raise AdapterError("workload manifest identity mismatch")
    for item in manifest["assets"]:
        filename = ASSET_FILES.get(item["identity"])
        if filename is None:
            raise AdapterError("workload manifest has an unknown adapter asset")
        asset_root = (
            root if item["identity"] == "invalid-fragment-shader"
            else WORKLOAD_ROOT / "masks-effects"
            if identity == "resource-reload" else root
        )
        if _sha256_file(asset_root / filename) != (item["sha256"], item["bytes"]):
            raise AdapterError(f"workload asset hash mismatch: {filename}")
    for item in manifest["inputs"]:
        filename = INPUT_FILES.get(item["identity"])
        if filename is None:
            raise AdapterError("workload manifest has an unknown adapter input")
        if _sha256_file(root / filename) != (item["sha256"], item["bytes"]):
            raise AdapterError(f"workload input hash mismatch: {filename}")
    reference = manifest["reference"]
    if _sha256_file(root / REFERENCE_FILE) != (
        reference["sha256"],
        reference["bytes"],
    ):
        raise AdapterError("workload reference hash mismatch")
    trace = contract.load_json(root / "trace-v1.json")
    reference_value = contract.load_json(root / REFERENCE_FILE)
    if trace.get("workload") != identity or reference_value.get("workload") != identity:
        raise AdapterError("workload material identity mismatch")
    return root, manifest, trace, reference_value


def _package_bytes(documents):
    entries = [
        (
            name.encode("utf-8"),
            document if isinstance(document, bytes)
            else contract.canonical_json_bytes(document),
        )
        for name, document in sorted(documents.items())
    ]
    version = b"PKGV0024"
    header = struct.pack("<I", len(version)) + version + struct.pack("<I", len(entries))
    offset = 0
    payloads = []
    for name, payload in entries:
        header += struct.pack("<I", len(name)) + name
        header += struct.pack("<II", offset, len(payload))
        payloads.append(payload)
        offset += len(payload)
    return header + b"".join(payloads)


def _materialize_project(
    workload_root, destination, scene_filename="scene.json", package_files=()
):
    project = destination / "project.json"
    package = destination / "scene.pkg"
    shutil.copyfile(workload_root / "project.json", project)
    documents = {"scene.json": contract.load_json(workload_root / scene_filename)}
    for filename in package_files:
        path = workload_root / filename
        documents[filename] = (
            contract.load_json(path) if path.suffix == ".json"
            else path.read_bytes()
        )
    package.write_bytes(_package_bytes(documents))
    return package


def _materialize_resource_reload_variant(workload_root, destination, package_files):
    project = destination / "project.json"
    package = destination / "scene.pkg"
    shutil.copyfile(workload_root / "project.json", project)
    documents = {"scene.json": contract.load_json(workload_root / "scene.json")}
    for filename in package_files:
        path = workload_root / filename
        documents[filename] = (
            contract.load_json(path) if path.suffix == ".json"
            else path.read_bytes()
        )
    shader = "shaders/effects/fresco_ordered_a.frag"
    documents[shader] = documents[shader].replace(
        b"vec4(0.8, 0.2, 0.1, 0.5)",
        b"vec4(0.1, 0.7, 0.9, 0.5)",
    )
    _require(documents[shader] != (workload_root / shader).read_bytes(),
             "resource reload shader variant was not produced")
    package.write_bytes(_package_bytes(documents))
    return package


def _materialize_invalid_shader_variant(
    workload_root, resource_root, destination, package_files
):
    project = destination / "project.json"
    package = destination / "scene.pkg"
    shutil.copyfile(workload_root / "project.json", project)
    documents = {"scene.json": contract.load_json(workload_root / "scene.json")}
    for filename in package_files:
        path = workload_root / filename
        documents[filename] = (
            contract.load_json(path) if path.suffix == ".json"
            else path.read_bytes()
        )
    documents["shaders/effects/fresco_ordered_a.frag"] = (
        resource_root / "invalid.frag"
    ).read_bytes()
    package.write_bytes(_package_bytes(documents))
    return package


PUPPET_GENERATED_FILES = (
    "models/masked.mdl",
    "models/unmasked.mdl",
    "materials/base.tex",
    "materials/masks/mask.tex",
)


def _generate_puppet_fixtures(workload_root, destination, timeout_seconds):
    source = workload_root / "generate_puppet_fixture.py"
    parameters = workload_root / "puppet-generator-parameters-v1.json"
    result = subprocess.run(
        [sys.executable, os.fspath(source), os.fspath(parameters),
         os.fspath(destination)],
        capture_output=True, text=True, timeout=timeout_seconds,
    )
    _require(result.returncode == 0,
             "deterministic puppet fixture generator failed")
    _require(not result.stdout and not result.stderr,
             "deterministic puppet fixture generator emitted diagnostics")
    outputs = {}
    evidence = {}
    for filename in PUPPET_GENERATED_FILES:
        generated = destination / filename
        reference = workload_root / "generated-puppet" / filename
        generated_digest = _sha256_file(generated)
        reference_digest = _sha256_file(reference)
        _require(generated_digest == reference_digest,
                 f"generated puppet output changed: {filename}")
        outputs[filename] = generated
        evidence[filename] = {
            "sha256": generated_digest[0], "bytes": generated_digest[1],
        }
    return outputs, {
        "generatorSource": {
            "sha256": _sha256_file(source)[0],
            "bytes": _sha256_file(source)[1],
        },
        "parameters": {
            "sha256": _sha256_file(parameters)[0],
            "bytes": _sha256_file(parameters)[1],
        },
        "outputs": evidence,
        "validation": [
            "mdlv0023-one-mesh",
            "normalized-root-weights",
            "bounded-u16-indices",
            "two-bounded-parts",
            "exact-mask-ordinals",
            "mdls0004-one-root-bone",
        ],
    }


def _materialize_puppet_project(
    workload_root, destination, scene_filename, generated
):
    shutil.copyfile(workload_root / "project.json", destination / "project.json")
    documents = {
        "scene.json": contract.load_json(workload_root / scene_filename),
        "models/puppet-masked.json": contract.load_json(
            workload_root / "models/puppet-masked.json"
        ),
        "models/puppet-unmasked.json": contract.load_json(
            workload_root / "models/puppet-unmasked.json"
        ),
        "materials/puppet.json": contract.load_json(
            workload_root / "materials/puppet.json"
        ),
    }
    documents.update({name: path.read_bytes() for name, path in generated.items()})
    package = destination / "scene.pkg"
    package.write_bytes(_package_bytes(documents))
    return package


def _materialize_media_project(workload_root, destination, texture):
    project = destination / "project.json"
    package = destination / "scene.pkg"
    shutil.copyfile(workload_root / "project.json", project)
    documents = {
        "scene.json": contract.load_json(workload_root / "scene.json"),
        "models/video.json": contract.load_json(
            workload_root / "models/video.json"
        ),
        "materials/video.json": contract.load_json(
            workload_root / "materials/video.json"
        ),
        "materials/video.tex": texture.read_bytes(),
    }
    package.write_bytes(_package_bytes(documents))
    return package


def _generate_media_fixtures(configuration, scratch):
    _require(
        configuration.media_fixture_generator is not None,
        "media-video requires a media fixture generator",
    )
    outputs = (
        scratch / "generated-media-container.tex",
        scratch / "generated-media-container-comparison.tex",
    )
    parameters = WORKLOAD_ROOT / "media-video" / "generator-parameters-v1.json"
    for output in outputs:
        completed = subprocess.run(
            [
                os.fspath(configuration.media_fixture_generator),
                os.fspath(parameters),
                os.fspath(output),
            ],
            capture_output=True,
            text=True,
            timeout=configuration.timeout_seconds,
            check=False,
        )
        _require(
            completed.returncode == 0,
            "media fixture generator failed: " + completed.stderr.strip(),
        )
        _require(output.is_file() and output.stat().st_size > 0,
                 "media fixture generator produced no container")
    first_sha256, first_bytes = _sha256_file(outputs[0])
    second_sha256, second_bytes = _sha256_file(outputs[1])
    generator_sha256, generator_bytes = _sha256_file(
        configuration.media_fixture_generator
    )
    evidence = {
        "identity": "generated-video-texture",
        "generatorAsset": "media-fixture-generator-source",
        "parametersInput": "media-generator-parameters-v1",
        "artifact": "generated-media-container",
        "comparisonArtifact": "generated-media-container-comparison",
        "generatorBinaryArtifact": "media-fixture-generator-binary",
        "byteReproducible": False,
        "actualSha256": first_sha256,
        "comparisonSha256": second_sha256,
        "byteIdentical": first_sha256 == second_sha256,
    }
    metadata = {
        "evidence": evidence,
        "paths": {
            "generated-media-container": outputs[0],
            "generated-media-container-comparison": outputs[1],
            "media-fixture-generator-binary": configuration.media_fixture_generator,
        },
        "bytes": {
            "generated-media-container": first_bytes,
            "generated-media-container-comparison": second_bytes,
            "media-fixture-generator-binary": generator_bytes,
        },
        "digests": {
            "generated-media-container": first_sha256,
            "generated-media-container-comparison": second_sha256,
            "media-fixture-generator-binary": generator_sha256,
        },
    }
    return outputs[0], metadata


class HelperProcess:
    def __init__(self, helper_binary, assignment, timeout_seconds, environment=None):
        self.assignment = assignment
        self.timeout_seconds = timeout_seconds
        self.commands = []
        self.stdout_lines = []
        self.stderr_chunks = []
        self._stdout_queue = queue.Queue()
        child_environment = os.environ.copy()
        child_environment.update(environment or {})
        self.process = subprocess.Popen(
            [os.fspath(helper_binary)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=child_environment,
        )
        self._stdout_thread = threading.Thread(target=self._drain_stdout)
        self._stderr_thread = threading.Thread(target=self._drain_stderr)
        self._stdout_thread.start()
        self._stderr_thread.start()

    def _drain_stdout(self):
        while True:
            line = self.process.stdout.readline()
            if not line:
                self._stdout_queue.put(None)
                return
            self._stdout_queue.put(line)

    def _drain_stderr(self):
        while True:
            chunk = self.process.stderr.read(4096)
            if not chunk:
                return
            self.stderr_chunks.append(chunk)

    def command(self, kind, **values):
        return {
            "protocolVersion": 1,
            "type": kind,
            "assignmentID": self.assignment,
            **values,
        }

    def send(self, kind, **values):
        command = self.command(kind, **values)
        self.commands.append(command)
        try:
            self.process.stdin.write(
                json.dumps(command, separators=(",", ":")) + "\n"
            )
            self.process.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            raise AdapterError(f"helper pipe failed during {kind}") from error
        return command

    def receive(self, expected):
        try:
            line = self._stdout_queue.get(timeout=self.timeout_seconds)
        except queue.Empty:
            raise AdapterError(f"helper timed out waiting for {expected}")
        if line is None:
            raise AdapterError(f"helper exited before emitting {expected}")
        self.stdout_lines.append(line)
        try:
            event = json.loads(line)
        except json.JSONDecodeError as error:
            raise AdapterError("helper emitted malformed JSON") from error
        if not isinstance(event, dict):
            raise AdapterError("helper event must be an object")
        if event.get("protocolVersion") != 1:
            raise AdapterError("helper event protocol version mismatch")
        if event.get("assignmentID") != self.assignment:
            raise AdapterError("helper event assignment mismatch")
        if event.get("type") != expected:
            raise AdapterError(
                f"helper event mismatch: expected {expected}, "
                f"found {event.get('type')}"
            )
        return event

    def exchange(self, kind, expected=None, **values):
        self.send(kind, **values)
        return self.receive(expected or kind)

    def stop(self):
        if self.process.poll() is not None:
            raise AdapterError("helper exited before stop")
        stopped = self.exchange("stop", "stopped")
        self.process.stdin.close()
        try:
            self.process.wait(timeout=self.timeout_seconds)
        except subprocess.TimeoutExpired as error:
            raise AdapterError("helper did not exit after stopped") from error
        self._stdout_thread.join(timeout=self.timeout_seconds)
        if self._stdout_thread.is_alive():
            raise AdapterError("helper stdout drain did not finish")
        self._stderr_thread.join(timeout=self.timeout_seconds)
        if self._stderr_thread.is_alive():
            raise AdapterError("helper stderr drain did not finish")
        if self.process.returncode != 0:
            raise AdapterError(f"helper exited with status {self.process.returncode}")
        return stopped

    def close(self):
        if self.process.poll() is None:
            try:
                self.process.terminate()
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        self._stdout_thread.join(timeout=2)
        if self.process.stdin is not None and not self.process.stdin.closed:
            self.process.stdin.close()
        if self.process.stdout is not None and not self.process.stdout.closed:
            self.process.stdout.close()
        self._stderr_thread.join(timeout=2)
        if self.process.stderr is not None and not self.process.stderr.closed:
            self.process.stderr.close()

    @property
    def stdout(self):
        return "".join(self.stdout_lines)

    @property
    def stderr(self):
        return "".join(self.stderr_chunks)

    def __enter__(self):
        return self

    def __exit__(self, _kind, _value, _traceback):
        self.close()


def _validate_candidate_event(event, configuration):
    _require(
        event.get("backend") == configuration.expected_backend,
        "helper backend does not match the expected backend",
    )
    if "renderer" in event:
        _require(
            event["renderer"] == configuration.expected_candidate,
            "helper candidate does not match the expected candidate",
        )
    backend = BACKENDS[configuration.expected_backend]
    _require(
        event.get("graphicsAPI") == backend["observedGraphicsAPI"],
        "helper graphics API does not match the expected backend",
    )
    _require(
        event.get("shaderTarget") == backend["observedShaderTarget"],
        "helper shader target does not match the expected backend",
    )


def _scheduler(event):
    evidence = event.get("schedulingEvidence")
    _require(isinstance(evidence, dict), "change-index scheduling evidence is required")
    required = {
        "decisions",
        "invalidations",
        "evaluations",
        "presentations",
        "presentationSuppressions",
        "externalPresentations",
        "missedDeadlines",
        "reasonCounts",
    }
    _require(required <= set(evidence), "scheduling evidence is incomplete")
    _require(
        all(
            isinstance(evidence[field], int) and not isinstance(evidence[field], bool)
            for field in required - {"reasonCounts"}
        ),
        "scheduling counters must be integers",
    )
    _require(
        isinstance(evidence["reasonCounts"], list)
        and len(evidence["reasonCounts"]) == 14
        and all(
            isinstance(value, int) and not isinstance(value, bool)
            for value in evidence["reasonCounts"]
        ),
        "scheduling reason counters are malformed",
    )
    return evidence


def _metric_event(event, configuration):
    _validate_candidate_event(event, configuration)
    _require(event.get("schedulingMechanism") == "change-index-v1", "wrong scheduler")
    _scheduler(event)
    for field in ("frames", "targetFPS", "elapsedMilliseconds"):
        _require(
            isinstance(event.get(field), (int, float))
            and not isinstance(event.get(field), bool),
            f"metrics field is missing: {field}",
        )
    return event


def _run_static(helper, configuration, trace, project):
    ready = helper.exchange(
        "load",
        "ready",
        path=os.fspath(project),
        assetRoot=os.fspath(configuration.asset_root),
        width=trace["logicalWidth"],
        height=trace["logicalHeight"],
        fps=trace["fpsCeiling"],
        policyRevision=trace["policyRevision"],
        reasonTokens=trace["reasonTokens"],
        staticContent=True,
        visible=True,
        muted=True,
    )
    _validate_candidate_event(ready, configuration)
    _require(ready.get("drawComplete") is True, "constructor draw did not complete")
    _require(
        ready.get("schedulingMode") == "static-present-on-change",
        "static scheduling mode was not selected",
    )
    _require(
        ready.get("schedulingMechanism") == "change-index-v1",
        "change-index scheduler was not selected",
    )
    _require(
        _scheduler(ready)["externalPresentations"] == 1,
        "constructor presentation evidence is not exact",
    )
    _require(_scheduler(ready)["invalidations"] == 0, "constructor invalidated")
    time.sleep(trace["settleMilliseconds"] / 1000.0)
    before = _metric_event(helper.exchange("metrics"), configuration)
    time.sleep(trace["quiescenceMilliseconds"] / 1000.0)
    quiescent = _metric_event(helper.exchange("metrics"), configuration)
    _require(
        quiescent["frames"] == before["frames"],
        "static renderer produced frames after quiescence",
    )
    before_scheduler = _scheduler(before)
    quiescent_scheduler = _scheduler(quiescent)
    _require(
        quiescent_scheduler["decisions"] == before_scheduler["decisions"] + 1,
        "static scheduler exceeded the metrics observation decision",
    )
    for field in ("evaluations", "presentations", "presentationSuppressions"):
        _require(
            quiescent_scheduler[field] == before_scheduler[field],
            f"static scheduler produced {field} after quiescence",
        )
    helper.exchange(
        "user-properties",
        "user-properties-applied",
        properties=trace["propertyInvalidation"],
    )
    changed = _metric_event(helper.exchange("metrics"), configuration)
    changed_scheduler = _scheduler(changed)
    _require(
        changed_scheduler["invalidations"]
        == quiescent_scheduler["invalidations"] + 1,
        "property update did not record exactly one invalidation",
    )
    for field in ("frames",):
        _require(
            changed[field] == quiescent[field] + 1,
            "property invalidation did not wake exactly one frame",
        )
    for field in ("evaluations", "presentations"):
        _require(
            changed_scheduler[field] == quiescent_scheduler[field] + 1,
            f"property invalidation did not wake exactly one {field}",
        )
    _require(
        changed_scheduler["decisions"] == quiescent_scheduler["decisions"] + 2,
        "property invalidation exceeded one wake plus one observation decision",
    )
    time.sleep(trace["quiescenceMilliseconds"] / 1000.0)
    requiescent = _metric_event(helper.exchange("metrics"), configuration)
    _require(
        requiescent["frames"] == changed["frames"],
        "property invalidation did not requiesce",
    )
    _require(
        _scheduler(requiescent)["decisions"] == changed_scheduler["decisions"] + 1,
        "scheduler exceeded the metrics observation decision after property wake",
    )
    for field in ("evaluations", "presentations", "presentationSuppressions"):
        _require(
            _scheduler(requiescent)[field] == changed_scheduler[field],
            f"scheduler produced {field} after property wake",
        )
    _require(
        _scheduler(requiescent)["invalidations"]
        == changed_scheduler["invalidations"],
        "static quiescence recorded an invalidation",
    )
    return ready, requiescent, {
        "constructor": ready,
        "beforeQuiescence": before,
        "afterQuiescence": quiescent,
        "afterPropertyInvalidation": changed,
        "afterPropertyRequiescence": requiescent,
        "metricsObservationDecisionCost": 1,
        "limitations": ["resize is not exposed by helper protocol version 1"],
    }


def _cadence_bounds(elapsed_milliseconds, ceiling, trace):
    expected = elapsed_milliseconds * ceiling / 1000.0
    minimum = max(
        trace["minimumLivenessFrames"],
        int(expected * trace["minimumRateMilli"] / 1000.0)
        - trace["frameSlack"],
    )
    maximum = int(expected) + trace["frameSlack"]
    return minimum, maximum


def _run_continuous(helper, configuration, trace, project):
    first = trace["phases"][0]
    revision = trace["initialPolicyRevision"]
    ready = helper.exchange(
        "load",
        "ready",
        path=os.fspath(project),
        assetRoot=os.fspath(configuration.asset_root),
        width=trace["logicalWidth"],
        height=trace["logicalHeight"],
        fps=first["fpsCeiling"],
        policyRevision=revision,
        reasonTokens=[trace["reasonToken"]],
        visible=True,
        muted=True,
    )
    _validate_candidate_event(ready, configuration)
    _require(ready.get("drawComplete") is True, "constructor draw did not complete")
    _require(
        ready.get("schedulingMode") == "legacy-continuous",
        "continuous scheduling mode was not selected",
    )
    _require(
        ready.get("schedulingMechanism") == "change-index-v1",
        "change-index scheduler was not selected",
    )
    phases = []
    retimings = []
    for index, phase in enumerate(trace["phases"]):
        ceiling = phase["fpsCeiling"]
        if index:
            revision += 1
            applied = helper.exchange(
                "scheduling-policy",
                "scheduling-policy-applied",
                fpsCeiling=ceiling,
                policyRevision=revision,
                reasonTokens=[trace["reasonToken"]],
            )
            _require(applied.get("fpsCeiling") == ceiling, "FPS retiming failed")
            _require(applied.get("policyRevision") == revision, "revision mismatch")
            retimings.append(applied)
        start = _metric_event(helper.exchange("metrics"), configuration)
        _require(start["targetFPS"] == ceiling, "metrics target FPS mismatch")
        time.sleep(phase["durationMilliseconds"] / 1000.0)
        end = _metric_event(helper.exchange("metrics"), configuration)
        elapsed = end["elapsedMilliseconds"] - start["elapsedMilliseconds"]
        frames = end["frames"] - start["frames"]
        minimum, maximum = _cadence_bounds(elapsed, ceiling, trace)
        _require(
            frames >= minimum,
            f"{ceiling} FPS phase fell below its declared cadence",
        )
        _require(frames <= maximum, f"{ceiling} FPS phase exceeded its ceiling")
        phases.append(
            {
                "fpsCeiling": ceiling,
                "elapsedMilliseconds": elapsed,
                "frames": frames,
                "minimumFrames": minimum,
                "maximumFrames": maximum,
                "start": start,
                "end": end,
            }
        )
    final_phase = phases[-1]["end"]
    reasons = _scheduler(final_phase)["reasonCounts"]
    _require(
        reasons[SCHEDULER_REASON_INDEX["lease-continuous"]] > 0,
        "continuous lease evidence is missing",
    )
    _require(
        reasons[SCHEDULER_REASON_INDEX["fps-ceiling"]] > 0,
        "FPS-ceiling coalescing evidence is missing",
    )
    pause_started = time.monotonic()
    helper.exchange("pause", "paused")
    pause_acknowledged_milliseconds = (time.monotonic() - pause_started) * 1000.0
    _require(
        pause_acknowledged_milliseconds <= trace["controlTimeoutMilliseconds"],
        "pause acknowledgement exceeded its declared bound",
    )
    paused_start = _metric_event(helper.exchange("metrics"), configuration)
    time.sleep(trace["pauseMilliseconds"] / 1000.0)
    paused_end = _metric_event(helper.exchange("metrics"), configuration)
    _require(paused_end.get("paused") is True, "pause state was not retained")
    _require(paused_end["frames"] == paused_start["frames"], "paused frames advanced")
    _require(
        _scheduler(paused_end)["invalidations"]
        == _scheduler(paused_start)["invalidations"],
        "pause observation recorded an invalidation",
    )
    _require(
        _scheduler(paused_end)["decisions"]
        == _scheduler(paused_start)["decisions"],
        "paused scheduler decisions advanced",
    )
    resume_started = time.monotonic()
    helper.exchange("resume", "resumed")
    resume_acknowledged_milliseconds = (
        time.monotonic() - resume_started
    ) * 1000.0
    _require(
        resume_acknowledged_milliseconds <= trace["controlTimeoutMilliseconds"],
        "resume acknowledgement exceeded its declared bound",
    )
    resumed_start = _metric_event(helper.exchange("metrics"), configuration)
    time.sleep(trace["resumeMilliseconds"] / 1000.0)
    resumed_end = _metric_event(helper.exchange("metrics"), configuration)
    _require(resumed_end.get("paused") is False, "resume state was not retained")
    _require(
        _scheduler(resumed_end)["invalidations"]
        == _scheduler(paused_end)["invalidations"] + 1,
        "resume did not record exactly one show invalidation",
    )
    resumed_elapsed = (
        resumed_end["elapsedMilliseconds"] - resumed_start["elapsedMilliseconds"]
    )
    resumed_frames = resumed_end["frames"] - resumed_start["frames"]
    resumed_minimum, resumed_maximum = _cadence_bounds(
        resumed_elapsed, trace["phases"][-1]["fpsCeiling"], trace
    )
    _require(resumed_frames >= resumed_minimum, "resume cadence was too slow")
    _require(resumed_frames <= resumed_maximum, "resume exceeded its FPS ceiling")
    return ready, resumed_end, {
        "phases": phases,
        "retimings": retimings,
        "pausedStart": paused_start,
        "pausedEnd": paused_end,
        "pauseAcknowledgedMilliseconds": pause_acknowledged_milliseconds,
        "resumedStart": resumed_start,
        "resumedEnd": resumed_end,
        "resumeAcknowledgedMilliseconds": resume_acknowledged_milliseconds,
        "frameSlack": trace["frameSlack"],
        "minimumRateMilli": trace["minimumRateMilli"],
        "resumeCadence": {
            "elapsedMilliseconds": resumed_elapsed,
            "frames": resumed_frames,
            "minimumFrames": resumed_minimum,
            "maximumFrames": resumed_maximum,
        },
        "limitations": [
            "fixture exercises continuous scheduling without authored visual motion",
            "deadline-bearing change stimulus is not exercised",
        ],
    }


def _run_script_heavy(helper, configuration, trace, timer_project, script_project):
    timer_ready = helper.exchange(
        "load", "ready", path=os.fspath(timer_project),
        assetRoot=os.fspath(configuration.asset_root),
        width=trace["logicalWidth"], height=trace["logicalHeight"],
        fps=trace["fpsCeiling"], policyRevision=trace["policyRevision"],
        reasonTokens=[trace["timerReasonToken"]], staticContent=True,
        visible=True, muted=True,
    )
    _validate_candidate_event(timer_ready, configuration)
    _require(timer_ready.get("schedulingMode") == "static-present-on-change",
             "timer fixture was not classified as tracked on-change")
    _require(timer_ready.get("genericPropertyScripts") == 1,
             "timer fixture script was not instantiated")
    _require(timer_ready.get("continuousGenericPropertyScripts") == 0,
             "timer-only script was misclassified as continuous")
    _require(timer_ready.get("deferredScriptValues") == 0,
             "timer fixture contains a deferred script")
    timer_initial = timer_ready.get("scriptTimers", {})
    _require(timer_initial.get("scheduled") == 1
             and timer_initial.get("pending") == 1
             and timer_initial.get("fired") == 0,
             "authored timer was not pending at ready")
    _require(timer_initial.get("lastScheduledDelayMilliseconds")
             == trace["timerDelayMilliseconds"], "authored timer delay changed")
    timer_observation_started = time.monotonic()
    time.sleep(trace["timerObservationMilliseconds"] / 1000.0)
    timer_fired = _metric_event(helper.exchange("metrics"), configuration)
    timer_observation_elapsed = (
        time.monotonic() - timer_observation_started
    ) * 1000.0
    _require(timer_observation_elapsed <= trace["timerHarnessTimeoutMilliseconds"],
             "timer observation exceeded the harness liveness timeout")
    fired = timer_fired.get("scriptTimers", {})
    _require(fired.get("scheduled") == 1 and fired.get("fired") == 1
             and fired.get("pending") == 0,
             "authored timer did not fire exactly once")
    timer_scheduler = _scheduler(timer_fired)
    _require(timer_scheduler.get("scriptTimerDeadlineSchedules") == 1,
             "authored timer did not schedule exactly one coordinator deadline")
    decision = timer_scheduler.get("lastDecision")
    _require(isinstance(decision, dict) and decision.get("evaluate") is True,
             "timer deadline did not produce an evaluating decision")
    reasons = decision.get("reasons", {}).get("values")
    _require(reasons == [LEASE_AT_REASON_INDEX],
             "timer deadline decision was masked by another demand")
    occurrences = decision.get("leaseOccurrences", {}).get("values")
    _require(isinstance(occurrences, list) and len(occurrences) == 1
             and occurrences[0].get("id") == 2
             and occurrences[0].get("mode") == 1,
             "timer deadline lease occurrence is missing")
    decision_time = decision.get("timeNanoseconds")
    scheduled_time = occurrences[0].get("scheduledTimeNanoseconds")
    _require(isinstance(decision_time, int) and not isinstance(decision_time, bool)
             and isinstance(scheduled_time, int)
             and not isinstance(scheduled_time, bool),
             "timer deadline timestamps are missing")
    _require(0 <= scheduled_time <= decision_time,
             "timer deadline occurrence contradicts its decision time")
    _require(trace["timerMinimumMilliseconds"] * 1_000_000 <= decision_time
             <= trace["timerMaximumMilliseconds"] * 1_000_000,
             "authored timer decision fell outside its coordinator-epoch bound")

    ready = helper.exchange(
        "load", "ready", path=os.fspath(script_project),
        assetRoot=os.fspath(configuration.asset_root),
        width=trace["logicalWidth"], height=trace["logicalHeight"],
        fps=trace["fpsCeiling"], policyRevision=trace["policyRevision"],
        reasonTokens=[trace["scriptReasonToken"]], visible=True, muted=True,
    )
    _validate_candidate_event(ready, configuration)
    _require(ready.get("genericPropertyScripts") == 2,
             "script fixture supported-script count changed")
    _require(ready.get("continuousGenericPropertyScripts") == 2,
             "authored update callbacks were not classified as continuous")
    _require(ready.get("deferredScriptValues") == 1,
             "authored unclassified script count changed")
    _require(ready.get("warnings") == [
        "1 instantiated SceneScript dynamic values are not yet evaluated"
    ], "deferred-script diagnostic changed")
    start = _metric_event(helper.exchange("metrics"), configuration)
    time.sleep(trace["continuousObservationMilliseconds"] / 1000.0)
    continuous = _metric_event(helper.exchange("metrics"), configuration)
    _require(continuous["frames"] > start["frames"],
             "time-driven script frames did not advance")
    _require(continuous.get("scriptTimeMilliseconds", 0)
             > start.get("scriptTimeMilliseconds", 0),
             "script time did not advance continuously")
    _require(continuous.get("genericPropertyScriptUpdates", 0)
             > start.get("genericPropertyScriptUpdates", 0),
             "authored update callbacks did not run continuously")
    _require(_scheduler(continuous)["reasonCounts"][7] > 0,
             "unclassified authored script did not remain fail-live")

    before_event = _scheduler(continuous)["invalidations"]
    cursor = helper.exchange("cursor-down", "cursor-event-dispatched", x=160, y=90)
    _require(cursor.get("handled") == 1, "authored cursor callback was not handled")
    after_event = _metric_event(helper.exchange("metrics"), configuration)
    _require(_scheduler(after_event)["invalidations"] == before_event + 1,
             "cursor callback did not record exactly one invalidation")

    before_property = _scheduler(after_event)["invalidations"]
    applied = helper.exchange(
        "user-properties", "user-properties-applied",
        properties={"character": {"value": True}}
    )
    _require(applied.get("diagnostics", []) == [],
             "property application emitted diagnostics")
    final = _metric_event(helper.exchange("metrics"), configuration)
    _require(_scheduler(final)["invalidations"] == before_property + 1,
             "property update did not record exactly one invalidation")
    _require(final.get("scriptErrors") == 0
             and final.get("genericPropertyScriptErrors") == 0,
             "script fixture emitted runtime errors")
    return ready, final, {
        "timerReady": timer_ready, "timerFired": timer_fired,
        "timerDecisionNanoseconds": decision_time,
        "timerScheduledNanoseconds": scheduled_time,
        "timerObservationElapsedMilliseconds": timer_observation_elapsed,
        "continuousStart": start, "continuousEnd": continuous,
        "afterCursor": after_event, "afterProperty": final,
        "limitations": [
            "semantic evidence does not claim pixel-reference correctness",
            "unclassified authored scripts remain fail-live and unevaluated",
        ],
    }


def _particle_resource_signature(metrics):
    allocations = metrics.get("renderAllocations")
    _require(isinstance(allocations, dict), "render allocation evidence is missing")
    signature = {}
    for identity, counters in sorted(allocations.items()):
        _require(isinstance(counters, dict), "render allocation counters are malformed")
        signature[identity] = {
            "allocations": counters.get("allocations"),
            "deallocations": counters.get("deallocations"),
        }
    particles = metrics.get("particles")
    _require(isinstance(particles, dict), "particle runtime evidence is missing")
    signature["programCache"] = {
        "entries": metrics.get("programCacheEntries"),
        "insertions": metrics.get("programCacheInsertions"),
    }
    signature["particlePool"] = {
        "capacity": particles.get("poolCapacity"),
        "resizes": particles.get("poolResizes"),
        "resourceInitializations": particles.get("resourceInitializations"),
    }
    return signature


def _run_particle_heavy(helper, configuration, trace, project, unknown_project):
    def load_fixture():
        event = helper.exchange(
            "load", "ready", path=os.fspath(project),
            assetRoot=os.fspath(configuration.asset_root),
            width=trace["logicalWidth"], height=trace["logicalHeight"],
            fps=trace["fpsCeiling"],
            policyRevision=trace["initialPolicyRevision"], reasonTokens=[],
            evidenceFrames=trace["evidenceFrames"], visible=True, muted=True,
        )
        _validate_candidate_event(event, configuration)
        _require(event.get("drawComplete") is True,
                 "particle constructor draw did not complete")
        _require(event.get("schedulingMode") == "tracked-particle-lifecycle",
                 "finite particle lifecycle was not selected")
        _require(event.get("warnings") == [],
                 "finite particle fixture emitted runtime warnings")
        return event

    unknown_ready = helper.exchange(
        "load", "ready", path=os.fspath(unknown_project),
        assetRoot=os.fspath(configuration.asset_root),
        width=trace["logicalWidth"], height=trace["logicalHeight"],
        fps=trace["fpsCeiling"],
        policyRevision=trace["initialPolicyRevision"], reasonTokens=[],
        evidenceFrames=trace["evidenceFrames"], visible=True, muted=True,
    )
    _validate_candidate_event(unknown_ready, configuration)
    _require(unknown_ready.get("schedulingMode") == "legacy-continuous",
             "unknown particle lifecycle did not remain fail-live")
    _require(unknown_ready.get("warnings") == [
        "1 particle systems have unknown lifecycle and remain continuously scheduled"
    ], "unknown particle lifecycle diagnostic changed")
    time.sleep(0.05)
    unknown_metrics = _metric_event(helper.exchange("metrics"), configuration)
    _require(unknown_metrics.get("particles", {}).get("unknownSystems") == 1,
             "unknown particle system was not counted")
    _require(_scheduler(unknown_metrics)["reasonCounts"][
        SCHEDULER_REASON_INDEX["lease-continuous"]
    ] > 0, "unknown particle system lost conservative continuous scheduling")

    first_ready = load_fixture()
    first_initial = _metric_event(helper.exchange("metrics"), configuration)
    ready = load_fixture()
    initial = _metric_event(helper.exchange("metrics"), configuration)
    first_particles = first_initial.get("particles", {})
    particles = initial.get("particles", {})
    deterministic_fields = (
        "systems", "finiteSystems", "unknownSystems", "minimumSeed",
        "maximumSeed", "emitted", "live",
        "peakLive", "poolCapacity", "poolResizes", "resourceInitializations",
        "updates", "stateHash",
    )
    _require(
        all(first_particles.get(field) == particles.get(field)
            for field in deterministic_fields),
        "same-seed particle reload changed initial simulation state",
    )
    _require(particles.get("systems") == 1
             and particles.get("finiteSystems") == 1
             and particles.get("unknownSystems") == 0,
             "finite particle classification evidence changed")
    _require(particles.get("minimumSeed") == trace["authoredSeed"]
             and particles.get("maximumSeed") == trace["authoredSeed"],
             "particle runtime seed does not match the authored object identifier")
    _require(particles.get("emitted") == 8 and particles.get("live") == 8,
             "authored instantaneous emission changed")
    _require(particles.get("updates", 0) >= 1,
             "particle simulation did not advance independently of frames")
    _require(isinstance(particles.get("stateHash"), int)
             and particles["stateHash"] != 0,
             "particle state hash is missing")
    _require(_scheduler(initial).get("particleLeaseAcquisitions") == 1
             and _scheduler(initial).get("particleLeaseReleases") == 0,
             "typed particle lease was not acquired exactly once")
    resources = _particle_resource_signature(initial)
    _require(resources["programCache"] == {"entries": 1, "insertions": 1},
             "particle program cache construction is not exact")
    _require(resources["particlePool"]["resizes"] == 0
             and resources["particlePool"]["resourceInitializations"] == 1,
             "particle resources were not initialized once from authored capacity")

    catch_up_policy = helper.exchange(
        "scheduling-policy", "scheduling-policy-applied",
        fpsCeiling=trace["catchUpFpsCeiling"],
        policyRevision=trace["catchUpPolicyRevision"],
        reasonTokens=[trace["catchUpReasonToken"]],
    )
    _require(catch_up_policy.get("fpsCeiling") == trace["catchUpFpsCeiling"],
             "particle catch-up policy was not applied")
    time.sleep(trace["catchUpObservationMilliseconds"] / 1000.0)
    catch_up = _metric_event(helper.exchange("metrics"), configuration)
    catch_particles = catch_up.get("particles", {})
    cumulative_fields = (
        "requestedMilliseconds", "simulatedMilliseconds", "droppedMilliseconds",
    )
    _require(
        all(
            isinstance(particles.get(field), (int, float))
            and not isinstance(particles.get(field), bool)
            and isinstance(catch_particles.get(field), (int, float))
            and not isinstance(catch_particles.get(field), bool)
            for field in cumulative_fields
        ),
        "particle cumulative catch-up counters are missing",
    )
    requested_delta = (
        catch_particles["requestedMilliseconds"]
        - particles["requestedMilliseconds"]
    )
    simulated_delta = (
        catch_particles["simulatedMilliseconds"]
        - particles["simulatedMilliseconds"]
    )
    dropped_delta = (
        catch_particles["droppedMilliseconds"]
        - particles["droppedMilliseconds"]
    )
    tolerance = trace["catchUpArithmeticToleranceMilliseconds"]
    _require(requested_delta >= 900,
             "particle catch-up cumulative request delta was not long")
    expected_simulated_delta = min(
        requested_delta, trace["maximumSimulatedMilliseconds"]
    )
    _require(abs(simulated_delta - expected_simulated_delta) <= tolerance,
             "particle catch-up simulation delta contradicts the cap")
    expected_dropped_delta = requested_delta - simulated_delta
    _require(abs(dropped_delta - expected_dropped_delta) <= tolerance,
             "particle catch-up dropped delta contradicts requested minus simulated")
    _require(catch_particles.get("catchUpFrames", 0) >= 1,
             "authored scheduling trace did not exercise particle catch-up")
    _require(catch_particles.get("maximumRequestedMilliseconds", 0) >= 900,
             "particle catch-up request was not observed")
    _require(catch_particles.get("maximumSimulatedMilliseconds", float("inf"))
             <= trace["maximumSimulatedMilliseconds"] + 0.001,
             "particle catch-up exceeded its simulation cap")
    _require(catch_particles.get("droppedMilliseconds", 0)
             >= trace["minimumDroppedMilliseconds"],
             "particle catch-up did not report dropped excess time")
    _require(_particle_resource_signature(catch_up) == resources,
             "particle render resources churned during catch-up")

    helper.exchange(
        "scheduling-policy", "scheduling-policy-applied",
        fpsCeiling=trace["fpsCeiling"],
        policyRevision=trace["resumePolicyRevision"],
        reasonTokens=[trace["resumeReasonToken"]],
    )
    deadline = time.monotonic() + trace["quiescenceTimeoutMilliseconds"] / 1000.0
    quiescent = None
    while time.monotonic() < deadline:
        time.sleep(0.05)
        candidate = _metric_event(helper.exchange("metrics"), configuration)
        candidate_particles = candidate.get("particles", {})
        candidate_scheduler = _scheduler(candidate)
        if (candidate_particles.get("quiescent") is True
                and candidate_particles.get("continuousRequired") is False):
            _require(candidate_scheduler.get("particleLeaseReleases") == 1,
                     "quiescent particle lifecycle did not release its lease")
        if (
            candidate_particles.get("quiescent") is True
            and candidate_particles.get("continuousRequired") is False
            and candidate_scheduler.get("particleLeaseReleases") == 1
        ):
            quiescent = candidate
            break
    _require(quiescent is not None,
             "finite particle lifecycle did not release its continuous lease")
    quiescent_particles = quiescent["particles"]
    _require(quiescent_particles.get("live") == 0,
             "particle lease released before the live set emptied")
    scheduler = _scheduler(quiescent)
    _require(scheduler.get("particleLeaseAcquisitions") == 1
             and scheduler.get("particleLeaseReleases") == 1,
             "typed particle lease lifecycle is not exact")
    _require(scheduler["reasonCounts"][SCHEDULER_REASON_INDEX["lease-continuous"]] > 0,
             "typed particle continuous-lease decisions are missing")
    _require(_particle_resource_signature(quiescent) == resources,
             "particle render resources churned before quiescence")

    time.sleep(trace["quiescenceObservationMilliseconds"] / 1000.0)
    after_quiescence = _metric_event(helper.exchange("metrics"), configuration)
    _require(after_quiescence["frames"] == quiescent["frames"],
             "finite particle renderer produced frames after quiescence")
    for field in ("evaluations", "presentations", "presentationSuppressions"):
        _require(_scheduler(after_quiescence)[field] == scheduler[field],
                 f"particle scheduler produced {field} after quiescence")
    _require(_scheduler(after_quiescence)["decisions"] == scheduler["decisions"] + 1,
             "particle quiescence exceeded the metrics observation decision")
    _require(_particle_resource_signature(after_quiescence) == resources,
             "particle resources changed after quiescence")
    return ready, after_quiescence, {
        "unknownReady": unknown_ready,
        "unknownMetrics": unknown_metrics,
        "firstReady": first_ready,
        "firstInitial": first_initial,
        "deterministicReloadReady": ready,
        "deterministicReloadInitial": initial,
        "deterministicFields": list(deterministic_fields),
        "catchUpPolicy": catch_up_policy,
        "catchUp": catch_up,
        "catchUpDeltas": {
            "requestedMilliseconds": requested_delta,
            "simulatedMilliseconds": simulated_delta,
            "droppedMilliseconds": dropped_delta,
            "arithmeticToleranceMilliseconds": tolerance,
        },
        "quiescent": quiescent,
        "afterQuiescence": after_quiescence,
        "resourceSignature": resources,
        "limitations": [
            "semantic evidence does not claim pixel-reference correctness",
            "only fully recognized finite emitters qualify for lifecycle scheduling",
            "unsupported particle graphs remain fail-live and continuously scheduled",
        ],
    }


def _media_metrics(event):
    media = event.get("mediaTextures")
    _require(isinstance(media, dict), "media texture evidence is missing")
    integer_fields = (
        "players", "referencedPlayers", "decodeAttempts", "decodedFrames",
        "frameReadyEvents", "stalledFrames", "frameUploads", "pendingFrames",
        "seekRequests", "fallbackPlayers", "globalLivePlayers",
        "globalPlayerConstructions", "globalPlayerDestructions",
        "lastDecodedFrameHash", "decodedFrameSequenceHash", "endOfStreamPlayers",
    )
    _require(
        all(isinstance(media.get(field), int)
            and not isinstance(media.get(field), bool)
            for field in integer_fields),
        "media texture counters are incomplete",
    )
    for field in (
        "framePreparationMilliseconds", "frameUploadMilliseconds",
        "decodeMilliseconds", "uploadSubmissionMilliseconds",
        "lastDecodedPresentationSeconds",
    ):
        _require(
            isinstance(media.get(field), (int, float))
            and not isinstance(media.get(field), bool),
            f"media texture metric is missing: {field}",
        )
    # The two totals cover the media player's per-frame entry points and the
    # two finer timers measure parts of them. A part exceeding its total means
    # the timer has come loose from the region it names.
    _require(
        media["framePreparationMilliseconds"] >= media["decodeMilliseconds"],
        "decode time exceeds the frame preparation it is measured inside",
    )
    _require(
        media["frameUploadMilliseconds"]
        >= media["uploadSubmissionMilliseconds"],
        "upload submission time exceeds the frame upload it is measured inside",
    )
    _require(media["decodeAttempts"] >= media["decodedFrames"],
             "decoded frames exceed decode attempts")
    _require(media["decodedFrames"] >= media["frameReadyEvents"],
             "frame-ready events exceed decoded frames")
    _require(media["frameReadyEvents"] >= media["frameUploads"],
             "frame uploads exceed frame-ready events")
    _require(media.get("decodes") == media["frameUploads"],
             "legacy decode counter is not the upload counter")
    return media


def _run_media_video(helper, configuration, trace, project, comparison_project):
    def load_fixture(path):
        event = helper.exchange(
            "load", "ready", path=os.fspath(path),
            assetRoot=os.fspath(configuration.asset_root),
            width=trace["logicalWidth"], height=trace["logicalHeight"],
            fps=trace["fpsCeiling"], policyRevision=trace["policyRevision"],
            reasonTokens=[], evidenceFrames=trace["evidenceFrames"],
            visible=True, muted=True,
        )
        _validate_candidate_event(event, configuration)
        _require(event.get("schedulingMode") == "tracked-media-lifecycle",
                 "exact media-only lifecycle was not selected")
        _require(event.get("warnings") == [],
                 "generated media fixture emitted runtime warnings")
        return event

    ready = load_fixture(project)
    initial = _metric_event(helper.exchange("metrics"), configuration)
    media_initial = _media_metrics(initial)
    _require(media_initial["players"] == 1
             and media_initial["referencedPlayers"] == 1
             and media_initial["fallbackPlayers"] == 0
             and media_initial["globalLivePlayers"] == 1,
             "media player construction evidence is not exact")
    _require(media_initial["decodeAttempts"] == 2
             and media_initial["decodedFrames"] == 2
             and media_initial["frameReadyEvents"] == 1
             and media_initial["frameUploads"] == 1
             and media_initial["pendingFrames"] == 1,
             "initial media upload and future PTS queue are not exact")
    # Every upload reaches the texture by blitting the decoder's IOSurface, on
    # both backends -- CGL on native OpenGL, EGL on ANGLE. Without this the
    # workload passes either way, because the mapped-pixel path stands behind
    # the blit and produces the same picture, so a silent fallback would cost a
    # 33 MB copy per frame and read as success. It is required of both because
    # a backend comparison where one blits and the other copies would charge
    # that copy to the backend.
    _require(
        media_initial["surfaceBlitUploads"] == media_initial["frameUploads"],
        "media uploads fell back off the IOSurface blit path",
    )
    first_frame_hash = media_initial["lastDecodedFrameHash"]
    first_sequence_hash = media_initial["decodedFrameSequenceHash"]
    _require(first_frame_hash != 0, "constructor decoded frame hash is missing")
    initial_scheduler = _scheduler(initial)
    _require(
        initial_scheduler.get("mediaFrameDeadlineSchedules", 0) == 1
        and initial_scheduler.get("mediaFrameDeadlineReplacements", 0) == 0
        and initial_scheduler.get("mediaFrameDeadlineReleases", 0) == 0
        and initial_scheduler.get("mediaFrameDeadlineActive") is True,
        "initial media deadline lifecycle is not exact",
    )

    time.sleep(trace["prePTSQuiescenceMilliseconds"] / 1000.0)
    pre_pts_quiescent = _metric_event(
        helper.exchange("metrics"), configuration
    )
    pre_pts_media = _media_metrics(pre_pts_quiescent)
    pre_pts_scheduler = _scheduler(pre_pts_quiescent)
    for field in (
        "decodeAttempts", "decodedFrames", "frameReadyEvents", "frameUploads",
        "decodedFrameSequenceHash",
    ):
        _require(
            pre_pts_media[field] == media_initial[field],
            f"active pre-PTS window changed media field {field}",
        )
    _require(pre_pts_quiescent["frames"] == initial["frames"],
             "active pre-PTS window presented a frame")
    for field in (
        "evaluations", "presentations", "presentationSuppressions",
        "mediaFrameDeadlineSchedules", "mediaFrameDeadlineReplacements",
        "mediaFrameDeadlineReleases",
    ):
        _require(
            pre_pts_scheduler.get(field, 0) == _scheduler(initial).get(field, 0),
            f"active pre-PTS window churned scheduler field {field}",
        )
    _require(
        pre_pts_scheduler["decisions"] == _scheduler(initial)["decisions"] + 1,
        "active pre-PTS window exceeded its metrics observation decision",
    )

    def inactive_signature(event):
        media = _media_metrics(event)
        scheduler = _scheduler(event)
        return {
            "frames": event["frames"],
            "decodeAttempts": media["decodeAttempts"],
            "decodedFrames": media["decodedFrames"],
            "frameReadyEvents": media["frameReadyEvents"],
            "frameUploads": media["frameUploads"],
            "lastDecodedPresentationSeconds": media[
                "lastDecodedPresentationSeconds"
            ],
            "decodedFrameSequenceHash": media["decodedFrameSequenceHash"],
            "decisions": scheduler["decisions"],
            "evaluations": scheduler["evaluations"],
            "presentations": scheduler["presentations"],
            "presentationSuppressions": scheduler["presentationSuppressions"],
            "mediaFrameDeadlineSchedules": scheduler.get(
                "mediaFrameDeadlineSchedules", 0
            ),
            "mediaFrameDeadlineReplacements": scheduler.get(
                "mediaFrameDeadlineReplacements", 0
            ),
            "mediaFrameDeadlineReleases": scheduler.get(
                "mediaFrameDeadlineReleases", 0
            ),
            "mediaFrameDeadlineActive": scheduler.get(
                "mediaFrameDeadlineActive", False
            ),
        }

    inactive_observations = {}
    previous_active = pre_pts_quiescent
    for deactivate, deactivated, activate, activated, label in (
        ("pause", "paused", "resume", "resumed", "pause"),
        ("hide", "hidden", "show", "shown", "hide"),
    ):
        before_position = _media_metrics(previous_active)[
            "lastDecodedPresentationSeconds"
        ]
        before_scheduler = _scheduler(previous_active)
        _require(before_scheduler.get("mediaFrameDeadlineActive") is True,
                 f"media {label} began without a live PTS deadline")
        helper.exchange(deactivate, deactivated)
        inactive_start = _metric_event(helper.exchange("metrics"), configuration)
        inactive_start_scheduler = _scheduler(inactive_start)
        _require(
            inactive_start_scheduler.get("mediaFrameDeadlineReleases", 0)
            == before_scheduler.get("mediaFrameDeadlineReleases", 0) + 1
            and inactive_start_scheduler.get("mediaFrameDeadlineActive") is False,
            f"media {label} did not release exactly one live deadline",
        )
        time.sleep(trace["inactiveObservationMilliseconds"] / 1000.0)
        inactive_end = _metric_event(helper.exchange("metrics"), configuration)
        _require(
            inactive_signature(inactive_end) == inactive_signature(inactive_start),
            f"media {label} interval produced decode/render/deadline churn",
        )
        helper.exchange(activate, activated)
        activated_start = _metric_event(
            helper.exchange("metrics"), configuration
        )
        activated_scheduler = _scheduler(activated_start)
        _require(
            activated_scheduler.get("mediaFrameDeadlineSchedules", 0)
            == inactive_start_scheduler.get("mediaFrameDeadlineSchedules", 0) + 1
            and activated_scheduler.get("mediaFrameDeadlineActive") is True,
            f"media {activate} did not acquire exactly one PTS deadline",
        )
        resumed_deadline = (
            time.monotonic() + trace["advanceTimeoutMilliseconds"] / 1000.0
        )
        resumed = None
        while time.monotonic() < resumed_deadline:
            candidate = _metric_event(helper.exchange("metrics"), configuration)
            if (_media_metrics(candidate)["frameUploads"]
                    > _media_metrics(inactive_end)["frameUploads"]):
                resumed = candidate
                break
            time.sleep(trace["pollMilliseconds"] / 1000.0)
        _require(resumed is not None, f"media {activate} did not resume PTS upload")
        resumed_position = _media_metrics(resumed)[
            "lastDecodedPresentationSeconds"
        ]
        _require(
            resumed_position >= before_position
            and resumed_position - before_position <= 0.251,
            f"media {activate} clock jumped across inactive wall time",
        )
        inactive_observations[label] = {
            "start": inactive_start,
            "end": inactive_end,
            "activated": activated_start,
            "resumed": resumed,
        }
        previous_active = resumed

    deadline = time.monotonic() + trace["advanceTimeoutMilliseconds"] / 1000.0
    advanced = None
    while time.monotonic() < deadline:
        time.sleep(trace["pollMilliseconds"] / 1000.0)
        candidate = _metric_event(helper.exchange("metrics"), configuration)
        if _media_metrics(candidate)["frameUploads"] >= 3:
            advanced = candidate
            break
    _require(advanced is not None, "PTS-driven media frames did not advance")
    media_advanced = _media_metrics(advanced)
    _require(advanced["frames"] - initial["frames"]
             == media_advanced["frameUploads"] - media_initial["frameUploads"],
             "media presentations were not gated by real frame uploads")
    _require(_scheduler(advanced).get("mediaFrameReadyInvalidations", 0)
             - _scheduler(initial).get("mediaFrameReadyInvalidations", 0)
             == media_advanced["frameReadyEvents"]
             - media_initial["frameReadyEvents"],
             "frame-ready invalidations do not match decoded-ready frames: "
             "typed invalidations "
             f"{_scheduler(initial).get('mediaFrameReadyInvalidations', 0)}->"
             f"{_scheduler(advanced).get('mediaFrameReadyInvalidations', 0)}, ready "
             f"{media_initial['frameReadyEvents']}->"
             f"{media_advanced['frameReadyEvents']}")
    _require(_scheduler(advanced).get("mediaFrameDeadlineSchedules", 0) > 0,
             "future media PTS did not schedule a typed deadline")
    advanced_scheduler = _scheduler(advanced)
    ready_presentations = advanced_scheduler.get(
        "mediaFrameReadyPresentations", 0
    )
    _require(ready_presentations > 0,
             "frame-ready presentation lacks causal revision evidence")
    _require(
        ready_presentations
        - _scheduler(initial).get("mediaFrameReadyPresentations", 0)
        == media_advanced["frameUploads"] - media_initial["frameUploads"],
        "media uploads lack exact frame-ready presentation evidence",
    )
    outstanding_ready = (
        advanced_scheduler.get("mediaFrameReadyInvalidations", 0)
        - ready_presentations
    )
    _require(
        outstanding_ready in (0, 1),
        "media frame-ready evidence has an invalid outstanding revision count",
    )
    last_ready = advanced_scheduler.get("lastMediaFrameReadyRevision")
    last_presented = advanced_scheduler.get(
        "lastPresentedMediaFrameReadyRevision"
    )
    _require(
        (
            outstanding_ready == 0 and last_ready == last_presented
        ) or (
            outstanding_ready == 1
            and isinstance(last_ready, int)
            and isinstance(last_presented, int)
            and last_ready > last_presented
        ),
        "media frame-ready revisions do not match their presentation state",
    )

    before_seek = advanced
    seek_applied = helper.exchange(
        "media-video", "media-video-applied", action="seek",
        positionSeconds=trace["seekSeconds"],
    )
    _require(
        seek_applied.get("deadlineMutation")
        in ("scheduled", "replaced", "retained")
        and seek_applied.get("deadlineArmed") is True,
        "media seek did not report one valid armed deadline mutation",
    )
    seek_deadline = time.monotonic() + trace["seekTimeoutMilliseconds"] / 1000.0
    sought = None
    while time.monotonic() < seek_deadline:
        candidate = _metric_event(helper.exchange("metrics"), configuration)
        media = _media_metrics(candidate)
        if (media["seekRequests"] == 1
                and media["frameUploads"]
                    > _media_metrics(before_seek)["frameUploads"]
                and candidate["frames"] > before_seek["frames"]
                and media["lastDecodedPresentationSeconds"]
                    >= trace["seekSeconds"]):
            sought = candidate
            break
        time.sleep(trace["pollMilliseconds"] / 1000.0)
    _require(sought is not None, "media seek did not decode the requested position")
    media_sought = _media_metrics(sought)
    sought_frame_hash = media_sought["lastDecodedFrameHash"]
    sought_sequence_hash = media_sought["decodedFrameSequenceHash"]
    _require(media_sought["lastDecodedFrameHash"] != first_frame_hash,
             "media seek did not change decoded semantic content")
    _require(sought["frames"] > before_seek["frames"],
             "seek-ready media frame was not presented")
    _require(
        _scheduler(sought).get("mediaFrameReadyInvalidations", 0)
        == _scheduler(before_seek).get("mediaFrameReadyInvalidations", 0) + 1,
        "seek-ready frame did not record exactly one typed invalidation",
    )
    before_eos = sought
    helper.exchange(
        "media-video", "media-video-applied", action="seek",
        positionSeconds=trace["endOfStreamSeekSeconds"],
    )
    # The seek lands in the gap between the final frame's presentation time and
    # the asset duration, so the next decode runs the reader to completion and
    # the player reaches end of stream. Video textures loop: the playback clock
    # folds position back to the start at the duration and the player resumes
    # decoding from there, so end of stream lasts a frame rather than the life of
    # the scene. Holding it was what froze Elaina's picture tens of seconds after
    # load while the frame loop carried on drawing the same final frame.
    #
    # The end-of-stream state itself is not polled for, because the fold clears
    # it well inside one poll interval. The stall it records is durable, so that
    # is the evidence the terminal path was reached at all.
    loop_deadline = time.monotonic() + trace["seekTimeoutMilliseconds"] / 1000.0
    looped = None
    last_loop_candidate = None
    media_before_eos = _media_metrics(before_eos)
    while time.monotonic() < loop_deadline:
        candidate = _metric_event(helper.exchange("metrics"), configuration)
        last_loop_candidate = candidate
        media = _media_metrics(candidate)
        if (media["stalledFrames"] > media_before_eos["stalledFrames"]
                and media["endOfStreamPlayers"] == 0
                and media["decodeAttempts"] > media_before_eos["decodeAttempts"]
                and media["lastDecodedPresentationSeconds"]
                    < trace["endOfStreamSeekSeconds"]):
            looped = candidate
            break
        time.sleep(trace["pollMilliseconds"] / 1000.0)
    _require(
        looped is not None,
        "video texture did not resume decoding after the playback clock wrapped;"
        " last=" + str(
            None if last_loop_candidate is None
            else _media_metrics(last_loop_candidate)
        ),
    )
    _require(_media_metrics(looped)["seekRequests"] == 2,
             "wrapped playback recorded an unexpected seek count")

    time.sleep(trace["quiescenceMilliseconds"] / 1000.0)
    running = _metric_event(helper.exchange("metrics"), configuration)
    media_running = _media_metrics(running)
    _require(media_running["endOfStreamPlayers"] == 0,
             "video texture latched end of stream after the wrap")
    _require(media_running["decodeAttempts"]
             > _media_metrics(looped)["decodeAttempts"],
             "decoder stopped attempting after the wrap")
    _require(media_running["frameUploads"]
             > _media_metrics(looped)["frameUploads"],
             "wrapped playback uploaded no further frames")
    _require(running["frames"] > looped["frames"],
             "wrapped media renderer stopped producing frames")
    for field in ("evaluations", "presentations"):
        _require(_scheduler(running)[field] > _scheduler(looped)[field],
                 f"wrapped media scheduler stopped advancing {field}")

    reload_ready = load_fixture(comparison_project)
    reloaded = _metric_event(helper.exchange("metrics"), configuration)
    media_reloaded = _media_metrics(reloaded)
    _require(media_reloaded["seekRequests"] == 0
             and media_reloaded["decodeAttempts"] == 2
             and media_reloaded["decodedFrames"] == 2
             and media_reloaded["frameUploads"] == 1
             and media_reloaded["pendingFrames"] == 1,
             "media session counters leaked across reload")
    _require(media_reloaded["lastDecodedFrameHash"] == first_frame_hash,
             "comparison container initial semantic hash differs")
    _require(media_reloaded["decodedFrameSequenceHash"] == first_sequence_hash,
             "comparison container initial semantic sequence differs")
    _require(media_reloaded["globalLivePlayers"] == 1
             and media_reloaded["globalPlayerConstructions"]
                 == media_initial["globalPlayerConstructions"] + 1
             and media_reloaded["globalPlayerDestructions"]
                 == media_initial["globalPlayerDestructions"] + 1,
             "media player lifecycle leaked across reload")
    helper.exchange(
        "media-video", "media-video-applied", action="seek",
        positionSeconds=trace["seekSeconds"],
    )
    comparison_deadline = (
        time.monotonic() + trace["seekTimeoutMilliseconds"] / 1000.0
    )
    comparison_sought = None
    while time.monotonic() < comparison_deadline:
        candidate = _metric_event(helper.exchange("metrics"), configuration)
        media = _media_metrics(candidate)
        if (media["seekRequests"] == 1 and media["frameUploads"] > 1
                and media["lastDecodedPresentationSeconds"]
                    >= trace["seekSeconds"]):
            comparison_sought = candidate
            break
        time.sleep(trace["pollMilliseconds"] / 1000.0)
    _require(comparison_sought is not None,
             "comparison container seek did not produce a frame")
    comparison_media = _media_metrics(comparison_sought)
    _require(comparison_media["lastDecodedFrameHash"] == sought_frame_hash,
             "comparison container seek semantic hash differs")
    _require(
        comparison_media["decodedFrameSequenceHash"] == sought_sequence_hash,
        "comparison container decoded sequence hash differs",
    )
    return reload_ready, comparison_sought, {
        "firstReady": ready,
        "initial": initial,
        "prePTSQuiescent": pre_pts_quiescent,
        "advanced": advanced,
        "sought": sought,
        "endOfStreamWrap": looped,
        "afterEndOfStreamWrap": running,
        "reloadReady": reload_ready,
        "reloaded": reloaded,
        "comparisonSought": comparison_sought,
        "inactiveLifecycle": inactive_observations,
        "sessionExecutionComponents": [running, comparison_sought],
        "decodedSemanticHash": first_frame_hash,
        "limitations": [
            "generated container bytes are derived run artifacts, not stable inputs",
            "correctness is semantic decode and lifecycle evidence, not pixel matching",
        ],
    }


def _float_hash(values):
    value = 1469598103934665603
    for item in values:
        for byte in struct.pack("<f", float(item)):
            value ^= byte
            value = (value * 1099511628211) & ((1 << 64) - 1)
    return value


def _audio_vector_evidence(values):
    left = [sum(values[index:index + 4]) / 4.0
            for index in range(0, 64, 4)]
    right = [sum(values[index:index + 4]) / 4.0
             for index in range(64, 128, 4)]
    vector_hash = (
        _float_hash(left) ^ ((_float_hash(right) * 1099511628211)
                             & ((1 << 64) - 1))
    )
    return vector_hash, (left[0] + right[0]) * 0.5


def _wait_for_metrics(helper, configuration, trace, predicate, description):
    deadline = time.monotonic() + trace["settleTimeoutMilliseconds"] / 1000.0
    last = None
    while time.monotonic() < deadline:
        last = _metric_event(helper.exchange("metrics"), configuration)
        if predicate(last):
            return last
        time.sleep(trace["pollMilliseconds"] / 1000.0)
    raise AdapterError(f"timed out waiting for {description}: {last}")


def _run_audio_reactive(
    helper, configuration, trace, project, unknown_project, near_match_project
):
    def load_fixture(path):
        event = helper.exchange(
            "load", "ready", path=os.fspath(path),
            assetRoot=os.fspath(configuration.asset_root),
            width=trace["logicalWidth"], height=trace["logicalHeight"],
            fps=trace["fpsCeiling"], policyRevision=trace["policyRevision"],
            reasonTokens=trace["reasonTokens"], evidenceFrames=1,
            visible=True, muted=True,
        )
        _validate_candidate_event(event, configuration)
        _require(event.get("drawComplete") is True,
                 "audio constructor draw did not complete")
        _require(event.get("warnings") == [],
                 "audio fixture emitted runtime warnings")
        return event

    unknown_ready = load_fixture(unknown_project)
    _require(unknown_ready.get("schedulingMode") == "legacy-continuous",
             "mixed audio scene did not remain fail-live")
    time.sleep(0.05)
    unknown_metrics = _metric_event(helper.exchange("metrics"), configuration)
    _require(_scheduler(unknown_metrics)["reasonCounts"][
        SCHEDULER_REASON_INDEX["lease-continuous"]
    ] > 0, "mixed audio scene lost conservative continuous scheduling")

    near_match_ready = helper.exchange(
        "load", "ready", path=os.fspath(near_match_project),
        assetRoot=os.fspath(configuration.asset_root),
        width=trace["logicalWidth"], height=trace["logicalHeight"],
        fps=trace["fpsCeiling"], policyRevision=trace["policyRevision"],
        reasonTokens=trace["reasonTokens"], evidenceFrames=1,
        visible=True, muted=True,
    )
    _validate_candidate_event(near_match_ready, configuration)
    _require(near_match_ready.get("schedulingMode") == "legacy-continuous",
             "near-match audio source incorrectly qualified for tracked lifecycle")
    time.sleep(0.05)
    near_match_metrics = _metric_event(
        helper.exchange("metrics"), configuration
    )
    _require(near_match_metrics.get("audioVectorScripts") == 1
             and near_match_metrics.get("exactTrackedAudioVectorScripts") == 0
             and near_match_metrics.get("deferredScriptValues") == 0,
             "near-match audio source lost generic rendering compatibility")
    _require(_scheduler(near_match_metrics)["reasonCounts"][
        SCHEDULER_REASON_INDEX["lease-continuous"]
    ] > 0, "near-match audio source did not remain conservatively live")

    ready = load_fixture(project)
    _require(ready.get("schedulingMode") == "tracked-audio-lifecycle",
             "exact audio lifecycle was not selected")
    initial = _metric_event(helper.exchange("metrics"), configuration)
    _require(initial.get("genericPropertyScripts") == 1
             and initial.get("continuousGenericPropertyScripts") == 1
             and initial.get("audioVectorScripts") == 1
             and initial.get("exactTrackedAudioVectorScripts") == 1
             and initial.get("deferredScriptValues") == 0,
             "exact audio-vector classifier evidence changed")
    _require(initial.get("soundControls") == []
             and initial.get("mediaTextures", {}).get("players") == 0,
             "audio fixture unexpectedly constructed output playback")
    _require(initial.get("muted") is True,
             "audio fixture did not begin output-muted")

    _require(_scheduler(initial).get("audioEnvelopeDeadlineActive") is True
             and _scheduler(initial).get("nextWakeNanoseconds") is not None,
             "constructor audio deadline did not publish its transport wake")
    time.sleep((1000 / trace["fpsCeiling"] + 50) / 1000.0)
    settled = _metric_event(helper.exchange("metrics"), configuration)
    _require(settled.get("audioVectorScriptUpdates") == 2
             and settled.get("audioVectorScriptChanges") == 1
             and settled.get("audioEnvelopeContinuousRequired") is False
             and _scheduler(settled).get("audioEnvelopeDeadlineActive") is False,
             "constructor envelope did not wake and settle without command polling")
    settled_scheduler = _scheduler(settled)
    _require(settled_scheduler.get("audioEnvelopeDeadlineSchedules") == 1
             and settled_scheduler.get("audioEnvelopeDeadlineReplacements") == 0
             and settled_scheduler.get("audioEnvelopeDeadlineReleases") == 0,
             "constructor deadline did not use natural one-shot consumption")

    helper.exchange("pause", "paused")
    paused_baseline = _metric_event(helper.exchange("metrics"), configuration)
    baseline_scheduler = _scheduler(paused_baseline)
    send_times = []
    start = time.monotonic()
    for sample in trace["samples"]:
        target = start + sample["offsetMilliseconds"] / 1000.0
        remaining = target - time.monotonic()
        if remaining > 0:
            time.sleep(remaining)
        send_times.append(time.monotonic())
        helper.send("audio-spectrum", values=sample["values"])
    acknowledgements = [
        helper.receive("audio-spectrum-applied") for _ in trace["samples"]
    ]
    for index, (sample, event) in enumerate(
        zip(trace["samples"], acknowledgements), start=1
    ):
        expected_vector_hash, expected_average = _audio_vector_evidence(
            sample["values"]
        )
        _require(event.get("changed") is True
                 and event.get("inputs") == index
                 and event.get("changes") == index,
                 "audio input acknowledgement counters are not exact")
        _require(event.get("spectrumHash") == _float_hash(sample["values"]),
                 "audio input acknowledgement has the wrong spectrum content")
        _require(event.get("vectorHash") == expected_vector_hash
                 and abs(event.get("vectorAverage0") - expected_average) < 1e-7
                 and abs(event.get("vectorAverage0")
                         - sample["expectedAverage0"]) < 1e-7,
                 "audio input did not reach the real stereo downsample path")
    observed_cadence = [
        round((sent - start) * 1000.0, 3) for sent in send_times
    ]
    _require(all(
        earlier <= later
        for earlier, later in zip(observed_cadence, observed_cadence[1:])
    ) and observed_cadence[-1] < trace["inputBurstWindowMilliseconds"],
             "manifest-bound audio burst exceeded one render interval")

    queued = _metric_event(helper.exchange("metrics"), configuration)
    queued_scheduler = _scheduler(queued)
    _require(queued["frames"] == paused_baseline["frames"]
             and queued_scheduler["evaluations"]
                 == baseline_scheduler["evaluations"]
             and queued_scheduler["presentations"]
                 == baseline_scheduler["presentations"],
             "paused spectrum cadence was coupled to render cadence")
    _require(queued.get("audioSpectrumInputs") == 3
             and queued.get("audioSpectrumChanges") == 3
             and queued_scheduler.get("audioReadyInvalidations") == 3,
             "queued spectrum input was not recorded exactly")

    helper.exchange("resume", "resumed")
    accepted = _wait_for_metrics(
        helper, configuration, trace,
        lambda event: (
            event.get("audioVectorScriptChanges") == 2
            and event.get("audioEnvelopeContinuousRequired") is True
            and _scheduler(event).get("audioReadyPresentations") == 1
            and _scheduler(event).get("audioEnvelopeDeadlineActive") is True
            and _scheduler(event).get("nextWakeNanoseconds") is not None
        ),
        "the latest queued spectrum to reach a causal presentation",
    )
    accepted_scheduler = _scheduler(accepted)
    _require(accepted_scheduler.get("lastPresentedAudioReadyRevision")
             == accepted_scheduler.get("lastAudioReadyRevision")
             and accepted_scheduler.get("lastAudioReadyDecisionSequence")
                 is not None,
             "audio-ready presentation was not causally linked")
    accepted_updates = accepted["audioVectorScriptUpdates"]
    accepted_changes = accepted["audioVectorScriptChanges"]
    _require(abs(accepted.get("audioVectorValueX") - 0.75) < 1e-6,
             "authored graph scale did not retain the accepted audio value")
    time.sleep((1000 / trace["fpsCeiling"] + 50) / 1000.0)
    naturally_settled = _metric_event(
        helper.exchange("metrics"), configuration
    )
    _require(naturally_settled.get("audioVectorScriptUpdates")
                 == accepted_updates + 1
             and naturally_settled.get("audioEnvelopeContinuousRequired") is False
             and _scheduler(naturally_settled).get(
                 "audioEnvelopeDeadlineActive"
             ) is False,
             "audio envelope did not wake for its unchanged due tick")
    natural_scheduler = _scheduler(naturally_settled)
    _require(naturally_settled["audioVectorScriptChanges"] == accepted_changes
             and natural_scheduler.get("audioEnvelopeDeadlineReleases") == 0
             and natural_scheduler.get("audioEnvelopeDeadlineReplacements") == 0,
             "natural envelope settling did not consume one due deadline")

    quarter = trace["samples"][0]
    helper.exchange("audio-spectrum", "audio-spectrum-applied",
                    values=quarter["values"])
    cancellation_ready = _wait_for_metrics(
        helper, configuration, trace,
        lambda event: (
            event.get("audioVectorScriptChanges") == accepted_changes + 1
            and _scheduler(event).get("audioEnvelopeDeadlineActive") is True
        ),
        "an envelope deadline for explicit cancellation",
    )
    cancellation_scheduler = _scheduler(cancellation_ready)
    _require(abs(cancellation_ready.get("audioVectorValueX") - 0.25) < 1e-6,
             "authored graph scale did not retain the quarter input")
    helper.exchange("pause", "paused")
    cancelled = _metric_event(helper.exchange("metrics"), configuration)
    _require(_scheduler(cancelled).get("audioEnvelopeDeadlineActive") is False
             and _scheduler(cancelled).get("audioEnvelopeDeadlineReleases")
                 == cancellation_scheduler.get("audioEnvelopeDeadlineReleases") + 1,
             "explicit pause did not release the pending audio deadline")
    helper.exchange("resume", "resumed")
    _wait_for_metrics(
        helper, configuration, trace,
        lambda event: (
            event.get("audioEnvelopeContinuousRequired") is False
            and _scheduler(event).get("audioEnvelopeDeadlineActive") is False
        ),
        "the explicitly cancelled envelope to settle after resume",
    )

    silence = trace["silence"]
    silence_ack = helper.exchange(
        "audio-spectrum", "audio-spectrum-applied", values=silence["values"]
    )
    expected_silence_hash, expected_silence_average = _audio_vector_evidence(
        silence["values"]
    )
    _require(silence_ack.get("changed") is True
             and silence_ack.get("spectrumHash")
                 == _float_hash(silence["values"])
             and silence_ack.get("vectorHash") == expected_silence_hash
             and expected_silence_average == silence["expectedAverage0"],
             "authored zero trace did not clear the spectrum")
    before_silence_change = cancellation_ready["audioVectorScriptChanges"]
    silence_changed = _wait_for_metrics(
        helper, configuration, trace,
        lambda event: (
            event.get("audioVectorScriptChanges", 0) > before_silence_change
            and event.get("audioEnvelopeContinuousRequired") is True
            and _scheduler(event).get("audioEnvelopeDeadlineActive") is True
        ),
        "the authored zero trace's changed tick",
    )
    silence_changes = silence_changed["audioVectorScriptChanges"]
    silence_updates = silence_changed["audioVectorScriptUpdates"]
    _require(abs(silence_changed.get("audioVectorValueX")) < 1e-6,
             "authored graph scale retained stale nonzero state at silence")
    time.sleep((1000 / trace["fpsCeiling"] + 50) / 1000.0)
    final = _metric_event(helper.exchange("metrics"), configuration)
    _require(final.get("audioVectorScriptUpdates") == silence_updates + 1
             and final.get("audioEnvelopeContinuousRequired") is False
             and _scheduler(final).get("audioEnvelopeDeadlineActive") is False,
             "silence envelope did not wake for its unchanged due tick")
    _require(final["audioVectorScriptChanges"] == silence_changes,
             "silence envelope did not settle on the unchanged due tick")
    final_frames = final["frames"]
    final_scheduler = _scheduler(final)
    time.sleep(trace["quiescenceMilliseconds"] / 1000.0)
    quiescent = _metric_event(helper.exchange("metrics"), configuration)
    _require(quiescent["frames"] == final_frames
             and _scheduler(quiescent)["evaluations"]
                 == final_scheduler["evaluations"]
             and _scheduler(quiescent)["presentations"]
                 == final_scheduler["presentations"],
             "settled silence produced an extra render wake")
    _require(quiescent.get("muted") is True
             and quiescent.get("soundControls") == [],
             "output-only mute leaked playback while accepting spectrum")

    reload_ready = load_fixture(project)
    _require(reload_ready.get("schedulingMode") == "tracked-audio-lifecycle",
             "audio lifecycle classification changed after reload")
    reloaded = _metric_event(helper.exchange("metrics"), configuration)
    _require(reloaded.get("audioSpectrumInputs") == 0
             and reloaded.get("audioSpectrumChanges") == 0
             and _scheduler(reloaded).get("audioReadyInvalidations") == 0
             and _scheduler(reloaded).get("audioReadyPresentations") == 0,
             "reload leaked prior audio input lifecycle evidence")

    return ready, reloaded, {
        "unknown": unknown_metrics,
        "nearMatch": near_match_metrics,
        "initial": initial,
        "settled": settled,
        "pausedBaseline": paused_baseline,
        "acknowledgements": acknowledgements,
        "observedInputOffsetsMilliseconds": observed_cadence,
        "queued": queued,
        "accepted": accepted,
        "naturallySettled": naturally_settled,
        "cancellationReady": cancellation_ready,
        "cancelled": cancelled,
        "silenceAcknowledgement": silence_ack,
        "silenceChanged": silence_changed,
        "final": final,
        "quiescent": quiescent,
        "reloaded": reloaded,
        "sessionExecutionComponents": [
            unknown_metrics, near_match_metrics, quiescent, reloaded,
        ],
    }


def _effect_output(event):
    return {
        "pixelRGBAHash": event.get("pixelRGBAHash"),
        "varyingPixels": event.get("varyingPixels"),
        "pixelProbes": event.get("pixelProbes"),
        "pixelRegions": event.get("pixelRegions"),
    }


def _puppet_output(event):
    return {
        "pixelRGBAHash": event.get("pixelRGBAHash"),
        "pixelRGBTotal": event.get("pixelRGBTotal"),
        "varyingPixels": event.get("varyingPixels"),
        "pixelProbes": event.get("pixelProbes"),
        "pixelRegions": event.get("pixelRegions"),
    }


def _effect_pass_graph(event):
    evidence = event.get("effectRender")
    _require(isinstance(evidence, dict), "effect pass evidence is missing")
    _require(evidence.get("truncatedPasses") == 0,
             "effect pass evidence was truncated")
    passes = evidence.get("orderedPasses")
    _require(isinstance(passes, list), "effect pass list is malformed")
    return passes


def _effect_allocation(metrics, identity):
    allocations = metrics.get("renderAllocations")
    _require(isinstance(allocations, dict),
             "effect render allocation evidence is missing")
    counters = allocations.get(identity)
    _require(isinstance(counters, dict),
             f"effect {identity} allocation evidence is missing")
    required = {"live", "peak", "allocations", "deallocations"}
    _require(required <= set(counters),
             f"effect {identity} allocation evidence is incomplete")
    return counters


def _run_masks_effects(
    helper, configuration, trace, project, masked_puppet_project,
    unmasked_puppet_project, generation_evidence,
):
    reference_backend = trace.get("equivalentOutputBackends", {}).get(
        configuration.expected_backend, configuration.expected_backend
    )
    expected = trace["expectedOutputs"].get(reference_backend)
    _require(isinstance(expected, dict),
             "effect workload has no reference for the expected backend")

    def validate_visible(event, label):
        _require(_effect_output(event) == expected["visible"],
                 f"{label} effect pixels do not match the exact reference")
        _require(_effect_pass_graph(event) == trace["orderedPasses"],
                 f"{label} effect pass order, targets, inputs, or blending changed")

    def load_fixture(label):
        event = helper.exchange(
            "load", "ready", path=os.fspath(project),
            assetRoot=os.fspath(configuration.asset_root),
            width=trace["logicalWidth"], height=trace["logicalHeight"],
            fps=trace["fpsCeiling"], policyRevision=trace["policyRevision"],
            reasonTokens=trace["reasonTokens"], visible=True, muted=True,
            pixelProbes=trace["pixelProbes"],
            pixelRegions=trace["pixelRegions"],
        )
        _validate_candidate_event(event, configuration)
        _require(event.get("drawComplete") is True,
                 "effect constructor draw did not complete")
        _require(event.get("warnings") == [],
                 "effect fixture emitted runtime warnings")
        _require(event.get("schedulingMode") == "legacy-continuous",
                 "effect scene did not remain conservatively fail-live")
        _require(event.get("schedulingMechanism") == "change-index-v1",
                 "effect scene did not use the change-index scheduler")
        validate_visible(event, label)
        return event

    ready = load_fixture("constructor")
    initial = _metric_event(helper.exchange("metrics"), configuration)
    for identity in ("intermediateFramebuffers", "intermediateTextures"):
        counters = _effect_allocation(initial, identity)
        _require(counters["live"] == 2 and counters["allocations"] == 2
                 and counters["deallocations"] == 0,
                 f"effect {identity} were not constructed exactly once")

    stable = helper.exchange("capture-frame-difference", "frame-difference")
    _validate_candidate_event(stable, configuration)
    validate_visible(stable, "stable capture")
    _require(stable.get("presented") is True
             and stable.get("changedPixels") == 0
             and stable.get("maximumChannelDelta") == 0
             and stable.get("totalChannelDelta") == 0,
             "unchanged effect capture was not pixel-stable")

    applied = helper.exchange(
        "user-properties", "user-properties-applied",
        properties=trace["hideProperty"],
    )
    _require(applied.get("diagnostics", []) == [],
             "effect visibility property emitted diagnostics")
    deadline = time.monotonic() + trace["damageTimeoutMilliseconds"] / 1000.0
    damaged = None
    while time.monotonic() < deadline:
        candidate = _metric_event(helper.exchange("metrics"), configuration)
        decision = _scheduler(candidate).get("lastDecision")
        damage = decision.get("damage") if isinstance(decision, dict) else None
        if isinstance(damage, dict):
            damaged = candidate
            break
        time.sleep(trace["pollMilliseconds"] / 1000.0)
    _require(damaged is not None,
             "property change did not produce observable damage evidence")
    damage = _scheduler(damaged)["lastDecision"]["damage"]
    _require(damage == {
        "conservativeUnknown": True,
        "expansion": "full-frame",
        "affectedIDs": {"count": 0, "values": [], "truncated": 0},
    }, "unknown effect damage was not conservatively expanded to full frame")

    hidden = helper.exchange("capture-frame-difference", "frame-difference")
    _validate_candidate_event(hidden, configuration)
    _require(_effect_output(hidden) == expected["hidden"],
             "hidden effect pixels do not match the exact reference")
    _require(_effect_pass_graph(hidden) == [],
             "hidden effect object still executed render passes")
    _require(hidden.get("changedPixels") == expected["changedPixels"],
             "effect visibility change touched an unexpected pixel set")
    effect_initial_final = _metric_event(
        helper.exchange("metrics"), configuration
    )

    reload_ready = load_fixture("reload")
    reloaded = _metric_event(helper.exchange("metrics"), configuration)
    for identity in ("intermediateFramebuffers", "intermediateTextures"):
        counters = _effect_allocation(reloaded, identity)
        _require(counters["live"] == 2 and counters["allocations"] == 4
                 and counters["deallocations"] == 2,
                 f"effect {identity} were stale or leaked across reload")

    puppet_expected = trace["expectedPuppetOutputs"].get(reference_backend)
    _require(isinstance(puppet_expected, dict),
             "puppet workload has no reference for the expected backend")

    def load_puppet(path, expected_output, expected_masks, label):
        event = helper.exchange(
            "load", "ready", path=os.fspath(path),
            assetRoot=os.fspath(configuration.asset_root),
            width=trace["logicalWidth"], height=trace["logicalHeight"],
            fps=trace["fpsCeiling"], policyRevision=trace["policyRevision"],
            reasonTokens=trace["reasonTokens"], visible=True, muted=True,
            evidenceFrames=1, pixelProbes=trace["puppetPixelProbes"],
            pixelRegions=trace["puppetPixelRegions"],
        )
        _validate_candidate_event(event, configuration)
        _require(event.get("drawComplete") is True and event.get("warnings") == [],
                 f"{label} puppet fixture did not draw cleanly")
        _require(event.get("schedulingMode") == "legacy-continuous",
                 f"{label} puppet fixture did not remain fail-live")
        _require(_puppet_output(event) == expected_output,
                 f"{label} puppet pixels do not match the exact reference")
        puppet = helper.exchange(
            "capture-puppet-evidence", "puppet-evidence"
        )
        _require(puppet.get("loadedMeshes") == 1
                 and puppet.get("loadedVertices") == 8
                 and puppet.get("loadedMasks") == expected_masks
                 and puppet.get("loadedAttachments") == 0
                 and puppet.get("simulationEnabledBoneCount") == 0
                 and puppet.get("activeIKBoneCount") == 0,
                 f"{label} puppet structural evidence changed")
        if expected_masks:
            _require(puppet.get("maskPasses") == 1,
                     "masked puppet did not execute exactly one stencil pass")
        else:
            _require(puppet.get("maskPasses") == 0,
                     "unmasked puppet unexpectedly executed a stencil pass")
        return event, puppet

    masked_ready, masked_puppet = load_puppet(
        masked_puppet_project, puppet_expected["masked"], 1, "masked"
    )
    masked_stable = helper.exchange(
        "capture-frame-difference", "frame-difference"
    )
    _validate_candidate_event(masked_stable, configuration)
    _require(_puppet_output(masked_stable) == puppet_expected["masked"]
             and masked_stable.get("changedPixels") == 0,
             "masked puppet output was not stable across draws")
    masked_after_draw = helper.exchange(
        "capture-puppet-evidence", "puppet-evidence"
    )
    _require(masked_after_draw.get("maskPasses")
             == masked_puppet.get("maskPasses") + 1,
             "masked puppet next draw did not execute exactly one stencil pass")
    masked_final_metrics = _metric_event(
        helper.exchange("metrics"), configuration
    )

    unmasked_ready, unmasked_puppet = load_puppet(
        unmasked_puppet_project, puppet_expected["unmasked"], 0, "unmasked"
    )
    _require(
        puppet_expected["masked"]["pixelProbes"][1]["rgba"]
        != puppet_expected["unmasked"]["pixelProbes"][1]["rgba"],
        "puppet target probe does not distinguish stencil composition",
    )
    unmasked_final_metrics = _metric_event(
        helper.exchange("metrics"), configuration
    )
    puppet_reload_ready, puppet_reloaded = load_puppet(
        masked_puppet_project, puppet_expected["masked"], 1, "reloaded masked"
    )
    puppet_final_metrics = _metric_event(
        helper.exchange("metrics"), configuration
    )

    return ready, puppet_final_metrics, {
        "initial": initial,
        "stable": stable,
        "damage": damaged,
        "hidden": hidden,
        "effectInitialFinal": effect_initial_final,
        "reloadReady": reload_ready,
        "reloaded": reloaded,
        "puppetGeneration": generation_evidence,
        "maskedPuppetReady": masked_ready,
        "maskedPuppet": masked_puppet,
        "maskedPuppetStable": masked_stable,
        "maskedPuppetAfterDraw": masked_after_draw,
        "maskedPuppetFinalMetrics": masked_final_metrics,
        "unmaskedPuppetReady": unmasked_ready,
        "unmaskedPuppet": unmasked_puppet,
        "unmaskedPuppetFinalMetrics": unmasked_final_metrics,
        "puppetReloadReady": puppet_reload_ready,
        "puppetReloaded": puppet_reloaded,
        "puppetFinalMetrics": puppet_final_metrics,
        "sessionExecutionComponents": [
            effect_initial_final,
            reloaded,
            masked_final_metrics,
            unmasked_final_metrics,
            puppet_final_metrics,
        ],
        "limitations": [
            "effect damage is conservatively expanded to the full frame",
            "effects remain fail-live and continuously scheduled",
        ],
    }


def _run_resource_reload(
    helper, configuration, trace, project_a, invalid_project, project_b
):
    reference_backend = trace.get("equivalentOutputBackends", {}).get(
        configuration.expected_backend, configuration.expected_backend
    )
    expected = trace["expectedOutputs"].get(reference_backend)
    _require(isinstance(expected, dict),
             "resource reload has no reference for the expected backend")
    expected_invalid_failure = trace["expectedFailureEvidence"].get(
        configuration.expected_backend
    )
    _require(isinstance(expected_invalid_failure, dict),
             "resource reload has no failure reference for the expected backend")
    invalid_program_rollbacks = expected_invalid_failure["programRollbacks"]
    invalid_compile_failures = expected_invalid_failure["shaderCompileFailures"]
    total_program_rollbacks = invalid_program_rollbacks + 1

    common = {
        "assetRoot": os.fspath(configuration.asset_root),
        "width": trace["logicalWidth"], "height": trace["logicalHeight"],
        "fps": trace["fpsCeiling"], "policyRevision": trace["policyRevision"],
        "reasonTokens": trace["reasonTokens"], "visible": True, "muted": True,
        "evidenceFrames": 1, "pixelProbes": trace["pixelProbes"],
        "pixelRegions": trace["pixelRegions"],
    }

    def load(
        path, output, generation, retired, last_retired,
        publications, rollbacks, entries, last_published, last_deleted, label,
    ):
        event = helper.exchange("load", "ready", path=os.fspath(path), **common)
        _validate_candidate_event(event, configuration)
        _require(_effect_output(event) == expected[output],
                 f"{label} pixels do not match the exact resource oracle")
        _require(event.get("programCacheEntries") == entries
                 and event.get("programCacheInsertions") == entries,
                 f"{label} reused or omitted generation-local programs")
        lifecycle = event.get("renderResourceLifecycle")
        _require(isinstance(lifecycle, dict)
                 and event.get("resourceGeneration") == generation
                 and lifecycle.get("lastCreatedGeneration") == generation
                 and lifecycle.get("generationsCreated") == generation
                 and lifecycle.get("generationsRetired") == retired
                 and lifecycle.get("liveGenerations") == 1
                 and lifecycle.get("completionBarriersRequested") == retired
                 and lifecycle.get("completionBarriersCompleted") == retired
                 and lifecycle.get("completionBarriersFailed") == 0
                 and lifecycle.get("retirementsWithoutCompletion") == 0
                 and lifecycle.get("lastRetiredGeneration") == last_retired
                 and lifecycle.get("lastCompletedGeneration") == last_retired
                 and lifecycle.get("programPublications") == publications
                 and lifecycle.get("lastPublishedGeneration") == last_published
                 and lifecycle.get("programDeletions")
                    == publications - entries
                 and lifecycle.get("lastDeletedGeneration")
                    == last_deleted
                 and lifecycle.get("programRollbacks") == rollbacks,
                 f"{label} generation or retirement evidence is not causal")
        metrics = _metric_event(helper.exchange("metrics"), configuration)
        _require(metrics.get("resourceGeneration") == generation
                 and metrics.get("programCacheEntries") == entries
                 and metrics.get("programCacheInsertions") == entries,
                 f"{label} metrics lost generation-local cache evidence")
        return event, metrics

    ready, first = load(
        project_a, "a", 1, 0, 0, 4, 0, 4, 1, 0, "first source A"
    )
    invalid_ready, invalid = load(
        invalid_project, "partial", 2, 1, 1, 5,
        invalid_program_rollbacks, 1, 2, 1, "real invalid shader"
    )
    invalid_lifecycle = invalid_ready.get("renderResourceLifecycle")
    _require(isinstance(invalid_lifecycle, dict)
             and invalid_lifecycle.get("programRollbacks")
                 == invalid_program_rollbacks
             and invalid_lifecycle.get("shaderCompileFailures")
                 == invalid_compile_failures
             and invalid_lifecycle.get("objectSetupFailures") == 1
             and invalid_lifecycle.get("lastObjectSetupFailureGeneration") == 2,
             "invalid shader rollback was not isolated and classified")
    injected_ready, injected = load(
        project_a, "partial", 3, 2, 2, 5,
        total_program_rollbacks, 0, 2, 2,
        "injected post-create rollback"
    )
    injected_lifecycle = injected_ready.get("renderResourceLifecycle")
    _require(isinstance(injected_lifecycle, dict)
             and injected_lifecycle.get("programRollbacks")
                 == total_program_rollbacks
             and injected_lifecycle.get("shaderCompileFailures")
                 == invalid_compile_failures
             and injected_lifecycle.get("objectSetupFailures") == 2
             and injected_lifecycle.get("lastObjectSetupFailureGeneration") == 3,
             "injected unpublished program was published, leaked, or not rolled back")
    same_ready, same = load(
        project_a, "a", 4, 3, 3, 9, total_program_rollbacks,
        4, 4, 2,
        "same-source reload"
    )
    changed_ready, changed = load(
        project_b, "b", 5, 4, 4, 13, total_program_rollbacks,
        4, 5, 4,
        "changed-source reload"
    )
    restored_ready, restored = load(
        project_a, "a", 6, 5, 5, 17, total_program_rollbacks,
        4, 6, 5,
        "restored source A"
    )
    return ready, restored, {
        "invalidReady": invalid_ready, "invalid": invalid,
        "injectedReady": injected_ready, "injected": injected,
        "first": first,
        "sameReady": same_ready,
        "same": same, "changedReady": changed_ready, "changed": changed,
        "restoredReady": restored_ready, "restored": restored,
        "sessionExecutionComponents": [
            first, invalid, injected, same, changed, restored,
        ],
        "limitations": [
            "retirement is synchronously completion-aware, not a deferred fence queue",
        ],
    }


def _write_json(path, value):
    path.write_bytes(contract.canonical_json_bytes(value) + b"\n")


def _artifact_set(
    scratch,
    store_root,
    workload_root,
    configuration,
    helper,
    observations,
    binary_sha256,
    generated_artifacts=None,
):
    paths = {
        "build-evidence": scratch / "build-evidence.json",
        "source-manifest": configuration.source_manifest,
        "protocol-commands": scratch / "protocol-commands.json",
        "helper-stdout": scratch / "helper.stdout.ndjson",
        "helper-stderr": scratch / "helper.stderr.txt",
        "semantic-evidence": scratch / "semantic-evidence.json",
        "semantic-reference": workload_root / REFERENCE_FILE,
    }
    _write_json(
        paths["build-evidence"],
        {
            "identity": configuration.build_identity,
            "sourceSha256": configuration.source_sha256,
            "binarySha256": binary_sha256,
            "commands": list(configuration.build_commands),
        },
    )
    _write_json(paths["protocol-commands"], helper.commands)
    paths["helper-stdout"].write_text(helper.stdout, encoding="utf-8")
    paths["helper-stderr"].write_text(helper.stderr, encoding="utf-8")
    _write_json(paths["semantic-evidence"], observations)
    media_types = {
        "build-evidence": "application/json",
        "source-manifest": "application/json",
        "protocol-commands": "application/json",
        "helper-stdout": "application/x-ndjson",
        "helper-stderr": "text/plain",
        "semantic-evidence": "application/json",
        "semantic-reference": "application/json",
    }
    for name, path in (generated_artifacts or {}).items():
        paths[name] = path
        media_types[name] = (
            "application/x-wallpaper-engine-texture"
            if "container" in name else "application/octet-stream"
        )
    return [
        contract.ingest_artifact(
            path, store_root, name, media_types[name]
        )
        for name, path in paths.items()
    ]


def _record(
    identity,
    manifest,
    configuration,
    started,
    completed,
    binary_sha256,
    ready,
    final_metrics,
    artifacts,
    generated_artifact_evidence=None,
    execution_totals=None,
):
    scheduler = _scheduler(final_metrics)
    execution = execution_totals or {
        "invalidations": scheduler["invalidations"],
        "evaluations": scheduler["evaluations"],
        "submissions": final_metrics["frames"],
        "presents": final_metrics["frames"],
        "suppressedPresents": scheduler["presentationSuppressions"],
        "missedDeadlines": scheduler["missedDeadlines"],
        "shaderCompilations": final_metrics["programCacheInsertions"],
        "pipelineCreations": final_metrics["programCacheInsertions"],
    }
    display = ready.get("display")
    _require(isinstance(display, dict), "ready display evidence is missing")
    display_fields = {
        "logicalWidth",
        "logicalHeight",
        "pixelWidth",
        "pixelHeight",
        "scaleMilli",
        "maximumRefreshMilliHertz",
        "colorSpace",
    }
    _require(display_fields <= set(display), "ready display evidence is incomplete")
    if identity not in {
        "script-heavy", "particle-heavy", "media-video", "audio-reactive",
        "masks-effects", "resource-reload",
    }:
        _require(
            ready.get("programCacheEntries") == 0
        and ready.get("programCacheInsertions") == 0
        and final_metrics.get("programCacheEntries") == 0
        and final_metrics.get("programCacheInsertions") == 0,
            "empty-scene shader program evidence must remain zero",
        )
    artifact_name = "semantic-evidence"
    checkpoints = [
        {
            "identity": item["identity"],
            "invariants": item["invariants"],
            "passed": True,
            "artifact": artifact_name,
        }
        for item in manifest["checkpoints"]
    ]
    assertions = [
        {"identity": item["identity"], "passed": True, "artifact": artifact_name}
        for item in manifest["invariants"]
    ]
    backend = BACKENDS[configuration.expected_backend]
    record = {
        "schemaVersion": 1,
        "run": {
            "identity": (
                f"{identity}-{configuration.expected_backend}-{binary_sha256[:12]}"
            ),
            "startedAtUtc": started,
            "completedAtUtc": completed,
            "operator": configuration.operator,
            "agentRole": configuration.agent_role,
            "purpose": "correctness",
            "sourceSha256": configuration.source_sha256,
            "binarySha256": binary_sha256,
            "workload": {
                "identity": identity,
                "version": manifest["workload"]["version"],
            },
            "manifestSha256": contract.manifest_hash(manifest),
            "assets": manifest["assets"],
            "inputs": manifest["inputs"],
            "seed": manifest["seed"],
        },
        "candidate": {
            "identity": configuration.expected_candidate,
            "backend": configuration.expected_backend,
            "graphicsApi": backend["graphicsApi"],
            "shaderApi": backend["shaderApi"],
        },
        "criteriaVersion": manifest["criteriaVersion"],
        "build": {
            "identity": configuration.build_identity,
            "sourceSha256": configuration.source_sha256,
            "binarySha256": binary_sha256,
            "commands": list(configuration.build_commands),
            "artifacts": ["build-evidence", "source-manifest"],
        },
        "host": {
            "os": f"{platform.system()} {platform.release()}",
            "architecture": platform.machine().lower(),
        },
        "display": display,
        "policy": {
            "revision": int(final_metrics["policyRevision"]),
            "fpsCeiling": int(final_metrics["targetFPS"]),
            "active": bool(final_metrics["active"]),
            "schedulerMode": final_metrics["schedulingMechanism"],
        },
        "correctness": {
            "reference": manifest["reference"],
            "checkpoints": checkpoints,
            "semanticAssertions": assertions,
            "graphicsErrors": _available(0),
            "artifacts": [
                "protocol-commands",
                "helper-stdout",
                "helper-stderr",
                "semantic-evidence",
                "semantic-reference",
            ],
        },
        "execution": {
            "invalidations": _available(execution["invalidations"]),
            "evaluations": _available(execution["evaluations"]),
            "submissions": _available(execution["submissions"]),
            "presents": _available(execution["presents"]),
            "suppressedPresents": _available(execution["suppressedPresents"]),
            "missedDeadlines": _available(execution["missedDeadlines"]),
        },
        "shaders": {
            "conditioningSchemaVersion": 1,
            "compilations": _available(execution["shaderCompilations"]),
            "pipelineCreations": _available(execution["pipelineCreations"]),
            "diagnostics": [],
        },
        "artifacts": artifacts,
        "verdict": {
            "accepted": True,
            "criteriaVersion": manifest["criteriaVersion"],
            "checks": {"build": True, "correctness": True, "diagnostics": True},
            "failures": [],
        },
    }
    if generated_artifact_evidence is not None:
        record["correctness"]["generatedArtifacts"] = [
            generated_artifact_evidence
        ]
        record["correctness"]["artifacts"].extend(
            [
                generated_artifact_evidence["artifact"],
                generated_artifact_evidence["comparisonArtifact"],
                generated_artifact_evidence["generatorBinaryArtifact"],
            ]
        )
    return record


def run_correctness(identity, configuration):
    configuration = _validate_configuration(configuration)
    workload_root, manifest, trace, _reference = _load_workload(identity)
    binary_sha256, _binary_bytes = _sha256_file(configuration.helper_binary)
    started = _utc_now()
    with tempfile.TemporaryDirectory(prefix="fresco-candidate-adapter.") as temporary:
        scratch = pathlib.Path(os.path.realpath(temporary))
        project = scratch / "project"
        project.mkdir()
        generated_media = None
        generated_puppet_evidence = None
        fixture_root = (
            WORKLOAD_ROOT / "masks-effects"
            if identity == "resource-reload" else workload_root
        )
        package_files = (
            "particles/finite.json", "materials/particle-fixture.json"
        ) if identity == "particle-heavy" else (
            "models/audio.json", "materials/audio.json"
        ) if identity == "audio-reactive" else ()
        if identity in {"masks-effects", "resource-reload"}:
            package_files = (
                "models/fixture.json",
                "materials/fixture.json",
                "effects/ordered/effect.json",
                "materials/effects/ordered-a.json",
                "materials/effects/ordered-b.json",
                "materials/effects/ordered-composite.json",
                "shaders/effects/fresco_ordered_a.vert",
                "shaders/effects/fresco_ordered_b.vert",
                "shaders/effects/fresco_ordered_composite.vert",
                "shaders/effects/fresco_ordered_a.frag",
                "shaders/effects/fresco_ordered_b.frag",
                "shaders/effects/fresco_ordered_composite.frag",
            )
        if identity == "media-video":
            texture, generated_media = _generate_media_fixtures(
                configuration, scratch
            )
            _materialize_media_project(workload_root, project, texture)
            comparison_project = scratch / "comparison-project"
            comparison_project.mkdir()
            _materialize_media_project(
                workload_root,
                comparison_project,
                generated_media["paths"][
                    "generated-media-container-comparison"
                ],
            )
        else:
            _materialize_project(fixture_root, project, package_files=package_files)
        if identity == "resource-reload":
            changed_project = scratch / "changed-project"
            changed_project.mkdir()
            _materialize_resource_reload_variant(
                fixture_root, changed_project, package_files
            )
            invalid_project = scratch / "invalid-project"
            invalid_project.mkdir()
            _materialize_invalid_shader_variant(
                fixture_root, workload_root, invalid_project, package_files
            )
        if identity == "masks-effects":
            generated_puppet = scratch / "generated-puppet"
            generated_outputs, generated_puppet_evidence = (
                _generate_puppet_fixtures(
                    workload_root, generated_puppet,
                    configuration.timeout_seconds,
                )
            )
            masked_puppet_project = scratch / "masked-puppet-project"
            masked_puppet_project.mkdir()
            _materialize_puppet_project(
                workload_root, masked_puppet_project,
                "puppet-masked-scene.json", generated_outputs,
            )
            unmasked_puppet_project = scratch / "unmasked-puppet-project"
            unmasked_puppet_project.mkdir()
            _materialize_puppet_project(
                workload_root, unmasked_puppet_project,
                "puppet-unmasked-scene.json", generated_outputs,
            )
        unknown_project = scratch / "unknown-particle-project"
        if identity == "particle-heavy":
            unknown_project.mkdir()
            _materialize_project(
                workload_root, unknown_project, "unknown-scene.json",
                package_files=(
                    "particles/unknown.json", "materials/particle-fixture.json",
                ),
            )
        if identity == "audio-reactive":
            unknown_project = scratch / "unknown-audio-project"
            unknown_project.mkdir()
            _materialize_project(
                workload_root, unknown_project, "unknown-scene.json",
                package_files=("models/audio.json", "materials/audio.json"),
            )
            near_match_project = scratch / "near-match-audio-project"
            near_match_project.mkdir()
            _materialize_project(
                workload_root, near_match_project, "near-match-scene.json",
                package_files=("models/audio.json", "materials/audio.json"),
            )
        timer_project = scratch / "timer-project"
        if identity == "script-heavy":
            timer_project.mkdir()
            _materialize_project(workload_root, timer_project, "timer-scene.json")
        helper = HelperProcess(
            configuration.helper_binary,
            trace["assignment"],
            configuration.timeout_seconds,
            environment={
                "FRESCO_SCENE_AUDIO_DISABLED": "1",
                "FRESCO_SCENE_SOUND_EXPERIMENTAL": "0",
                **({"FRESCO_SCENE_TEST_FAIL_SHADER_PROGRAM_ONCE": "3"}
                   if identity == "resource-reload" else {}),
            },
        )
        with helper:
            hello = helper.exchange("hello")
            _validate_candidate_event(hello, configuration)
            if identity == "static-no-media":
                ready, final_metrics, observations = _run_static(
                    helper, configuration, trace, project
                )
            elif identity == "continuous-animation":
                ready, final_metrics, observations = _run_continuous(
                    helper, configuration, trace, project
                )
            elif identity == "script-heavy":
                ready, final_metrics, observations = _run_script_heavy(
                    helper, configuration, trace,
                    timer_project / "scene.pkg", project / "scene.pkg",
                )
            elif identity == "particle-heavy":
                ready, final_metrics, observations = _run_particle_heavy(
                    helper, configuration, trace, project, unknown_project
                )
            elif identity == "media-video":
                ready, final_metrics, observations = _run_media_video(
                    helper, configuration, trace, project / "scene.pkg",
                    comparison_project / "scene.pkg",
                )
            elif identity == "audio-reactive":
                ready, final_metrics, observations = _run_audio_reactive(
                    helper, configuration, trace, project, unknown_project,
                    near_match_project,
                )
            elif identity == "masks-effects":
                ready, final_metrics, observations = _run_masks_effects(
                    helper, configuration, trace, project,
                    masked_puppet_project, unmasked_puppet_project,
                    generated_puppet_evidence,
                )
            else:
                ready, final_metrics, observations = _run_resource_reload(
                    helper, configuration, trace, project, invalid_project,
                    changed_project,
                )
            stopped = helper.stop()
            if identity == "media-video":
                lifecycle = stopped.get("mediaTextureLifecycle")
                _require(isinstance(lifecycle, dict),
                         "stopped event omitted media lifecycle evidence")
                _require(lifecycle.get("livePlayers") == 0,
                         "media player remained live after stop")
                _require(lifecycle.get("constructions")
                         == lifecycle.get("destructions"),
                         "media player construction/destruction totals differ")
                observations["stopped"] = stopped
            if identity == "masks-effects":
                allocations = stopped.get("renderAllocations")
                _require(isinstance(allocations, dict),
                         "stopped event omitted effect allocation evidence")
                for allocation_identity in (
                    "intermediateFramebuffers", "intermediateTextures",
                ):
                    counters = allocations.get(allocation_identity)
                    _require(isinstance(counters, dict)
                             and counters.get("live") == 0
                             and counters.get("allocations") == 4
                             and counters.get("deallocations") == 4,
                             f"effect {allocation_identity} remained live after stop")
                observations["stopped"] = stopped
            if identity == "resource-reload":
                lifecycle = stopped.get("renderResourceLifecycle")
                _require(isinstance(lifecycle, dict)
                         and lifecycle.get("generationsCreated") == 6
                         and lifecycle.get("generationsRetired") == 6
                         and lifecycle.get("liveGenerations") == 0
                         and lifecycle.get("completionBarriersRequested") == 6
                         and lifecycle.get("completionBarriersCompleted") == 6
                         and lifecycle.get("completionBarriersFailed") == 0
                         and lifecycle.get("retirementsWithoutCompletion") == 0
                         and lifecycle.get("lastCompletedGeneration") == 6
                         and lifecycle.get("programPublications") == 17
                         and lifecycle.get("programDeletions") == 17
                         and lifecycle.get("lastPublishedGeneration") == 6
                         and lifecycle.get("lastDeletedGeneration") == 6
                         and lifecycle.get("programRollbacks")
                            == trace["expectedFailureEvidence"][
                                configuration.expected_backend
                            ]["programRollbacks"] + 1
                         and lifecycle.get("shaderCompileFailures")
                            == trace["expectedFailureEvidence"][
                                configuration.expected_backend
                            ]["shaderCompileFailures"]
                         and lifecycle.get("lastCreatedGeneration") == 6
                         and lifecycle.get("lastRetiredGeneration") == 6,
                         "resource generations did not retire cleanly at stop")
                observations["stopped"] = stopped
        execution_components = observations.get(
            "sessionExecutionComponents", [final_metrics]
        )
        execution_totals = {
            "invalidations": sum(
                _scheduler(item)["invalidations"]
                for item in execution_components
            ),
            "evaluations": sum(
                _scheduler(item)["evaluations"]
                for item in execution_components
            ),
            "submissions": sum(item["frames"] for item in execution_components),
            "presents": sum(item["frames"] for item in execution_components),
            "suppressedPresents": sum(
                _scheduler(item)["presentationSuppressions"]
                for item in execution_components
            ),
            "missedDeadlines": sum(
                _scheduler(item)["missedDeadlines"]
                for item in execution_components
            ),
            "shaderCompilations": sum(
                item["programCacheInsertions"] for item in execution_components
            ),
            "pipelineCreations": sum(
                item["programCacheInsertions"] for item in execution_components
            ),
        }
        multi_session_execution = len(execution_components) > 1
        _require(not helper.stderr, "helper emitted diagnostics on stderr")
        completed = _utc_now()
        observations = {
            "schemaVersion": 1,
            "workload": identity,
            "backend": configuration.expected_backend,
            "candidate": configuration.expected_candidate,
            "hello": hello,
            "observations": observations,
            "recordDerivations": {
                "invalidations": {
                    "value": execution_totals["invalidations"],
                    "source": (
                        "sum of final per-session schedulingEvidence invalidations"
                        if multi_session_execution
                        else "helper schedulingEvidence invalidations"
                    ),
                },
                "submissions": {
                    "value": execution_totals["submissions"],
                    "source": (
                        "sum of final per-session helper metrics frames"
                        if multi_session_execution else "helper metrics frames"
                    ),
                },
                "presents": {
                    "value": execution_totals["presents"],
                    "source": (
                        "sum of final per-session helper metrics frames "
                        "incremented after surface.present"
                        if multi_session_execution else
                        "helper metrics frames incremented after surface.present"
                    ),
                },
                "graphicsErrors": {
                    "value": 0,
                    "source": "completed draws fail on any graphics API error",
                },
                "shaderCompilations": {
                    "value": execution_totals["shaderCompilations"],
                    "source": (
                        "sum of final per-session generated program insertions"
                        if multi_session_execution else
                        "helper cumulative generated program insertions"
                    ),
                },
                "pipelineCreations": {
                    "value": execution_totals["pipelineCreations"],
                    "source": (
                        "sum of final per-session generated program insertions"
                        if multi_session_execution else
                        "helper cumulative generated program insertions"
                    ),
                },
                "sessions": [
                    {
                        "invalidations": _scheduler(item)["invalidations"],
                        "evaluations": _scheduler(item)["evaluations"],
                        "submissions": item["frames"],
                        "presents": item["frames"],
                        "suppressedPresents": _scheduler(item)[
                            "presentationSuppressions"
                        ],
                        "missedDeadlines": _scheduler(item)["missedDeadlines"],
                        "shaderCompilations": item["programCacheInsertions"],
                        "pipelineCreations": item["programCacheInsertions"],
                    }
                    for item in execution_components
                ],
            },
        }
        artifacts = _artifact_set(
            scratch,
            configuration.store_root,
            workload_root,
            configuration,
            helper,
            observations,
            binary_sha256,
            None if generated_media is None else generated_media["paths"],
        )
        record = _record(
            identity,
            manifest,
            configuration,
            started,
            completed,
            binary_sha256,
            ready,
            final_metrics,
            artifacts,
            None if generated_media is None else generated_media["evidence"],
            execution_totals,
        )
        path = contract.write_record(record, manifest, configuration.store_root)
    return record, path
