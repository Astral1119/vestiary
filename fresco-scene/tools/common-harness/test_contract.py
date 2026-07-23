#!/usr/bin/env python3

import copy
import hashlib
import json
import os
import pathlib
import tempfile
import unittest
from unittest import mock

import contract


def digest(label):
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def available(value):
    return {"status": "available", "value": value}


def hash_item(identity, label):
    return {"identity": identity, "sha256": digest(label), "bytes": len(label)}


def reject_record(record, failure="synthetic failure"):
    record["verdict"]["accepted"] = False
    record["verdict"]["failures"] = [failure]
    return record


def descriptor_count():
    return len(os.listdir("/dev/fd"))


def manifest(identity="static-no-media", criteria="baseline-v1"):
    return {
        "schemaVersion": 1,
        "workload": {
            "identity": identity,
            "version": 1,
            "classification": contract.WORKLOADS[identity]["classification"],
        },
        "criteriaVersion": criteria,
        "assets": [hash_item("scene", "scene")],
        "inputs": [hash_item("trace", "trace")],
        "reference": hash_item("reference-frame", "reference"),
        "seed": 7,
        "checkpoints": [
            {
                "identity": "first-frame",
                "atNanoseconds": 0,
                "invariants": ["frame-matches"],
            }
        ],
        "invariants": [
            {"identity": "frame-matches", "description": "Frame matches reference."}
        ],
    }


class Fixture:
    def __init__(self, temporary):
        self.root = pathlib.Path(os.path.realpath(temporary))
        source_directory = self.root / "sources"
        source_directory.mkdir()
        self.build_source = source_directory / "build.log"
        self.frame_source = source_directory / "frame.rgba"
        self.leak_source = source_directory / "leaks.txt"
        self.build_source.write_bytes(b"build evidence\n")
        self.frame_source.write_bytes(b"rgba evidence")
        self.leak_source.write_bytes(b"no leaks\n")
        self.build = contract.ingest_artifact(
            self.build_source, self.root, "build-log", "text/plain"
        )
        self.frame = contract.ingest_artifact(
            self.frame_source, self.root, "frame", "application/octet-stream"
        )
        self.leak = contract.ingest_artifact(
            self.leak_source, self.root, "leak-log", "text/plain"
        )
        self.lifecycle_reference_value = {
            "schemaVersion": 1,
            "workload": "static-no-media",
            "profile": "lifecycle",
            "required": {
                "createDestroyIterations": 2,
                "reloadIterations": 2,
                "generationsPerIteration": 2,
                "completionBarriersPerIteration": 2,
                "liveGenerationsAfterStop": 0,
                "programPublicationDeletionBalance": True,
                "ownedProcessesAfterStop": 0,
                "atExitLeakCount": 0,
            },
            "resourceCriteria": {
                "processes": {"before": 0, "after": 0, "peakAtLeast": 1},
                "childProcesses": {"before": 0, "after": 0, "peakAtLeast": 0},
                "rssBytes": {"before": 0, "after": 0, "peakAtLeast": 1},
                "threads": {"before": 0, "after": 0, "peakAtLeast": 1},
                "fileDescriptors": {"before": 0, "after": 0, "peakAtLeast": 1},
                "trackedPrograms": {"before": 0, "after": 0, "peakAtLeast": 1},
                "trackedRendererAllocations": {
                    "before": 0, "after": 0, "peakAtLeast": 0,
                },
            },
            "deviceLoss": {
                "status": "unavailable",
                "reason": "synthetic backend exposes no loss injection",
            },
            "driverGpuResources": {
                "status": "unavailable",
                "reason": "synthetic driver exposes no resource counters",
            },
            "metricDefinitions": {
                "trackedPrograms": "program entries",
                "trackedRendererAllocations": "live allocation counters",
            },
        }
        reference_source = source_directory / "lifecycle-reference.json"
        reference_source.write_bytes(
            contract.canonical_json_bytes(self.lifecycle_reference_value)
        )
        self.lifecycle_reference = contract.ingest_artifact(
            reference_source, self.root, "lifecycle-reference", "application/json"
        )

    def lifecycle_manifest(self):
        value = manifest(criteria="lifecycle-v1")
        value["reference"] = {
            "identity": "lifecycle-reference",
            "sha256": self.lifecycle_reference["sha256"],
            "bytes": self.lifecycle_reference["bytes"],
        }
        return value

    def run(self, purpose, role="root-agent"):
        criteria = "lifecycle-v1" if purpose == "lifecycle" else "baseline-v1"
        workload_manifest = manifest(criteria=criteria)
        return {
            "identity": f"synthetic-{purpose}",
            "startedAtUtc": "2026-07-22T08:00:00Z",
            "completedAtUtc": "2026-07-22T08:00:01Z",
            "operator": "synthetic-test",
            "agentRole": role,
            "purpose": purpose,
            "sourceSha256": digest("source"),
            "binarySha256": digest("binary"),
            "workload": {"identity": "static-no-media", "version": 1},
            "manifestSha256": contract.manifest_hash(workload_manifest),
            "assets": workload_manifest["assets"],
            "inputs": workload_manifest["inputs"],
            "seed": workload_manifest["seed"],
        }

    def build_section(self):
        return {
            "identity": "synthetic-build",
            "sourceSha256": digest("source"),
            "binarySha256": digest("binary"),
            "commands": ["cmake --build build --target synthetic"],
            "artifacts": ["build-log"],
        }

    def correctness(self, *, full=False):
        diagnostics = []
        if full:
            diagnostics.append(
                {
                    "severity": "warning",
                    "code": "synthetic-warning",
                    "message": "Synthetic diagnostic.",
                    "artifact": "build-log",
                }
            )
        return {
            "schemaVersion": 1,
            "run": self.run("correctness"),
            "candidate": {
                "identity": "synthetic-candidate",
                "backend": "synthetic",
                "graphicsApi": "synthetic-api",
                "shaderApi": "synthetic-shader",
            },
            "criteriaVersion": "baseline-v1",
            "build": self.build_section(),
            "host": {"os": "Synthetic OS", "architecture": "arm64"},
            "display": {
                "logicalWidth": 320,
                "logicalHeight": 180,
                "pixelWidth": 640,
                "pixelHeight": 360,
                "scaleMilli": 2000,
                "maximumRefreshMilliHertz": 60000,
                "colorSpace": "sRGB",
            },
            "policy": {
                "revision": 1,
                "fpsCeiling": 60,
                "active": True,
                "schedulerMode": "change-index-v1",
            },
            "correctness": {
                "reference": hash_item("reference-frame", "reference"),
                "checkpoints": [
                    {
                        "identity": "first-frame",
                        "invariants": ["frame-matches"],
                        "passed": True,
                        "artifact": "frame",
                    }
                ],
                "semanticAssertions": [
                    {"identity": "frame-matches", "passed": True, "artifact": "frame"}
                ],
                "graphicsErrors": available(0),
                "artifacts": ["frame"],
            },
            "execution": {
                "invalidations": available(1),
                "evaluations": available(1),
                "submissions": available(1),
                "presents": available(1),
                "suppressedPresents": available(0),
                "missedDeadlines": available(0),
            },
            "shaders": {
                "conditioningSchemaVersion": 1,
                "compilations": available(1),
                "pipelineCreations": available(1),
                "diagnostics": diagnostics,
            },
            "artifacts": [self.build, self.frame],
            "verdict": {
                "accepted": True,
                "criteriaVersion": "baseline-v1",
                "checks": {"build": True, "correctness": True, "diagnostics": True},
                "failures": [],
            },
        }

    def lifecycle_section(self, *, full=False):
        processes = [
            {
                "role": "candidate",
                "executableSha256": digest("binary"),
                "parentRole": None,
            }
        ]
        if full:
            processes.append(
                {
                    "role": "helper",
                    "executableSha256": digest("helper"),
                    "parentRole": "candidate",
                }
            )
        resources = {
            "rssBytes": {
                "before": available(100),
                "after": available(100),
                "peak": available(120),
            },
            "threads": {
                "before": available(1),
                "after": available(1),
                "peak": available(2),
            },
            "fileDescriptors": {
                "before": available(3),
                "after": available(3),
                "peak": available(4),
            },
        }
        if full:
            resources["gpuResources"] = {
                "before": available(0),
                "after": available(0),
                "peak": available(3),
            }
        return {
            "processManifest": processes,
            "iterations": {
                "createDestroy": available(2),
                "reload": available(2),
                "deviceLoss": available(1),
            },
            "resources": resources,
            "leakEvidence": {
                "tool": "synthetic leak checker",
                "status": "clean",
                "artifact": "leak-log",
            },
            "artifacts": ["leak-log"],
        }

    def lifecycle(self, *, full=False):
        return {
            "schemaVersion": 1,
            "run": self.run("lifecycle"),
            "candidate": {
                "identity": "synthetic-candidate",
                "backend": "synthetic",
                "graphicsApi": "synthetic-api",
                "shaderApi": "synthetic-shader",
            },
            "criteriaVersion": "lifecycle-v1",
            "build": self.build_section(),
            "lifecycle": self.lifecycle_section(full=full),
            "artifacts": [self.build, self.leak],
            "verdict": {
                "accepted": True,
                "criteriaVersion": "lifecycle-v1",
                "checks": {
                    "build": True,
                    "lifecycle": True,
                    "resources": True,
                    "leaks": True,
                },
                "failures": [],
            },
        }

    def lifecycle_v2(self, *, gpu_available=True):
        record = self.lifecycle()
        workload_manifest = self.lifecycle_manifest()
        tracked_program_peak = 3 if gpu_available else 0
        record["schemaVersion"] = 2
        record["run"]["manifestSha256"] = contract.manifest_hash(workload_manifest)
        record["lifecycle"]["processManifest"] = [
            {**process, "ownedByRun": True}
            for process in record["lifecycle"]["processManifest"]
        ]
        record["lifecycle"]["iterations"]["deviceLoss"] = {
            "status": "unavailable",
            "reason": "synthetic backend exposes no loss injection",
        }
        record["lifecycle"]["resources"] = {
            "processes": {
                "status": "available", "before": 0, "after": 0, "peak": 1,
            },
            "childProcesses": {
                "status": "available", "before": 0, "after": 0, "peak": 0,
            },
            "rssBytes": {
                "status": "available", "before": 0, "after": 0, "peak": 120,
            },
            "threads": {
                "status": "available", "before": 0, "after": 0, "peak": 2,
            },
            "fileDescriptors": {
                "status": "available", "before": 0, "after": 0, "peak": 4,
            },
            "trackedPrograms": {
                "status": "available", "before": 0, "after": 0,
                "peak": tracked_program_peak,
            },
            "trackedRendererAllocations": {
                "status": "available", "before": 0, "after": 0, "peak": 2,
            },
            "driverGpuResources": {
                "status": "unavailable",
                "reason": "synthetic driver exposes no resource counters",
            },
        }
        if not gpu_available:
            record["verdict"]["accepted"] = False
            record["verdict"]["checks"]["resources"] = False
        record["lifecycle"]["leakEvidence"]["tool"] = {
            "identity": "synthetic-leak-tool",
            "version": "1",
            "executableSha256": self.leak["sha256"],
            "artifact": "leak-log",
        }
        raw_value = {
            "schemaVersion": 2,
            "auditor": {"identity": "synthetic"},
            "iterations": [
                {
                    "iteration": iteration,
                    "snapshots": [{
                        "totals": {
                            "processes": 1,
                            "childProcesses": 0,
                            "rssBytes": 120,
                            "threads": 2,
                            "fileDescriptors": 4,
                        }
                    }],
                    "firstLoad": {
                        "programCacheEntries": tracked_program_peak,
                        "liveRendererAllocations": 2,
                    },
                    "reload": {
                        "programCacheEntries": tracked_program_peak,
                        "liveRendererAllocations": 2,
                    },
                    "stoppedLifecycle": {
                        "generationsCreated": 2,
                        "generationsRetired": 2,
                        "liveGenerations": 0,
                        "completionBarriersCompleted": 2,
                        "completionBarriersFailed": 0,
                        "retirementsWithoutCompletion": 0,
                        "programPublications": 3,
                        "programDeletions": 3,
                    },
                    "ownedProcessesAfterStop": [],
                }
                for iteration in (1, 2)
            ],
            "atExitLeakReport": {
                "leakCount": 0,
                "leakedBytes": 0,
                "clean": True,
                "stdout": "Process 1: 0 leaks for 0 total leaked bytes.",
            },
            "matchedAppKitControl": {
                "leakCount": 0,
                "leakedBytes": 0,
                "clean": True,
                "stdout": "Process 2: 0 leaks for 0 total leaked bytes.",
                "eventTypes": ["hello", "ready", "stopped"],
            },
            "resourcePeaks": {
                "processes": 1,
                "childProcesses": 0,
                "rssBytes": 120,
                "threads": 2,
                "fileDescriptors": 4,
                "trackedPrograms": tracked_program_peak,
                "trackedRendererAllocations": 2,
            },
            "deviceLoss": self.lifecycle_reference_value["deviceLoss"],
        }
        raw_source = self.root / "sources" / "lifecycle-raw.json"
        raw_source.write_bytes(contract.canonical_json_bytes(raw_value))
        raw_artifact = contract.ingest_artifact(
            raw_source, self.root, "lifecycle-raw", "application/json"
        )
        record["lifecycle"]["leakEvidence"]["artifact"] = "lifecycle-raw"
        record["lifecycle"]["artifacts"] = [
            "lifecycle-raw", "lifecycle-reference", "leak-log",
        ]
        record["artifacts"] = [
            self.build, self.leak, raw_artifact, self.lifecycle_reference,
        ]
        return record


class ContractTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fresco-common-harness.")
        self.fixture = Fixture(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def assert_rejected(self, value, message=None):
        with self.assertRaises(contract.ContractError, msg=message):
            contract.validate_result(value)

    def assert_lifecycle_rejected(self, value, pattern=None):
        context = (
            self.assertRaisesRegex(contract.ContractError, pattern)
            if pattern is not None
            else self.assertRaises(contract.ContractError)
        )
        with context:
            contract.validate_result_against_manifest(
                value, self.fixture.lifecycle_manifest(), self.fixture.root
            )

    def replace_lifecycle_evidence(self, record, mutate):
        descriptor = next(
            artifact for artifact in record["artifacts"]
            if artifact["name"] == "lifecycle-raw"
        )
        value = contract.load_json(self.fixture.root / descriptor["path"])
        mutate(value)
        source = self.fixture.root / "sources" / "mutated-lifecycle-raw.json"
        source.write_bytes(contract.canonical_json_bytes(value))
        replacement = contract.ingest_artifact(
            source, self.fixture.root, "lifecycle-raw", "application/json"
        )
        record["artifacts"] = [
            replacement if artifact["name"] == "lifecycle-raw" else artifact
            for artifact in record["artifacts"]
        ]

    def assert_fd_count_stable(self, operation, exception=contract.ContractError):
        before = descriptor_count()
        for _ in range(32):
            with self.assertRaises(exception):
                operation()
        self.assertEqual(descriptor_count(), before)

    def derived_artifact_case(self):
        workload_manifest = manifest()
        workload_manifest["assets"].append(
            hash_item("media-fixture-generator-source", "generator source")
        )
        workload_manifest["inputs"].append(
            hash_item("media-fixture-generator-parameters", "generator parameters")
        )
        relationship = {
            "identity": "generated-video-texture",
            "generatorAsset": "media-fixture-generator-source",
            "parametersInput": "media-fixture-generator-parameters",
            "artifact": "generated-media-container",
            "comparisonArtifact": "generated-media-container-comparison",
            "generatorBinaryArtifact": "media-fixture-generator-binary",
            "byteReproducible": False,
        }
        workload_manifest["schemaVersion"] = 2
        workload_manifest["derivedArtifacts"] = [relationship]

        record = self.fixture.correctness()
        record["run"]["assets"] = copy.deepcopy(workload_manifest["assets"])
        record["run"]["inputs"] = copy.deepcopy(workload_manifest["inputs"])
        record["run"]["manifestSha256"] = contract.manifest_hash(workload_manifest)
        actual = contract.ingest_artifact(
            self.fixture.frame_source,
            self.fixture.root,
            relationship["artifact"],
            "application/octet-stream",
        )
        comparison = contract.ingest_artifact(
            self.fixture.leak_source,
            self.fixture.root,
            relationship["comparisonArtifact"],
            "application/octet-stream",
        )
        generator_binary = contract.ingest_artifact(
            self.fixture.build_source,
            self.fixture.root,
            relationship["generatorBinaryArtifact"],
            "application/octet-stream",
        )
        record["artifacts"].extend([actual, comparison, generator_binary])
        record["correctness"]["generatedArtifacts"] = [
            {
                **relationship,
                "actualSha256": actual["sha256"],
                "comparisonSha256": comparison["sha256"],
                "byteIdentical": False,
            }
        ]
        return workload_manifest, record

    def test_catalog_and_manifest_contract(self):
        primary = [
            item for item in contract.WORKLOADS.values()
            if item["classification"] == "primary"
        ]
        deferred = [
            item for item in contract.WORKLOADS.values()
            if item["classification"] == "deferred"
        ]
        self.assertEqual(len(primary), 9)
        self.assertEqual(len(deferred), 3)
        self.assertEqual(
            contract.WORKLOADS["static-no-media"]["implementation"],
            "adapter-baseline",
        )
        self.assertEqual(
            contract.WORKLOADS["continuous-animation"]["implementation"],
            "adapter-baseline",
        )
        self.assertTrue(
            all(
                item["implementation"] in {"contract-only", "adapter-baseline"}
                for item in primary
            )
        )
        value = manifest()
        contract.validate_manifest(value)
        self.assertEqual(contract.manifest_hash(value), contract.canonical_hash(value))

        unknown = copy.deepcopy(value)
        unknown["workload"]["identity"] = "unknown"
        with self.assertRaises(contract.ContractError):
            contract.validate_manifest(unknown)
        forward = copy.deepcopy(value)
        forward["schemaVersion"] = 3
        with self.assertRaises(contract.ContractError):
            contract.validate_manifest(forward)
        version_two = copy.deepcopy(value)
        version_two["schemaVersion"] = 2
        contract.validate_manifest(version_two)
        frozen_v1 = copy.deepcopy(value)
        frozen_v1["derivedArtifacts"] = []
        with self.assertRaisesRegex(contract.ContractError, "version 1"):
            contract.validate_manifest(frozen_v1)
        with self.assertRaisesRegex(contract.ContractError, "manifest hash"):
            contract.validate_result_against_manifest(
                self.fixture.correctness(), version_two, self.fixture.root
            )
        extra = copy.deepcopy(value)
        extra["future"] = True
        with self.assertRaises(contract.ContractError):
            contract.validate_manifest(extra)

    def test_valid_minimal_and_full_correctness_and_lifecycle(self):
        for record in (
            self.fixture.correctness(),
            self.fixture.correctness(full=True),
            self.fixture.lifecycle(),
            self.fixture.lifecycle(full=True),
            self.fixture.lifecycle_v2(),
            self.fixture.lifecycle_v2(gpu_available=False),
        ):
            workload_manifest = (
                self.fixture.lifecycle_manifest()
                if record["schemaVersion"] == 2
                else manifest(criteria=record["criteriaVersion"])
            )
            contract.validate_result_against_manifest(
                record,
                workload_manifest,
                artifact_root=self.fixture.root,
            )

    def test_lifecycle_v2_requires_owned_processes_and_explicit_unavailability(self):
        unowned = self.fixture.lifecycle_v2()
        unowned["lifecycle"]["processManifest"][0]["ownedByRun"] = False
        self.assert_rejected(unowned)

        missing_loss_reason = self.fixture.lifecycle_v2()
        missing_loss_reason["lifecycle"]["iterations"]["deviceLoss"] = {
            "status": "unavailable"
        }
        self.assert_rejected(missing_loss_reason)

        unavailable_rss = self.fixture.lifecycle_v2()
        unavailable_rss["lifecycle"]["resources"]["rssBytes"] = {
            "status": "unavailable",
            "reason": "synthetic absence",
        }
        self.assert_rejected(unavailable_rss)

        invalid_peak = self.fixture.lifecycle_v2()
        invalid_peak["lifecycle"]["resources"]["threads"]["after"] = 1
        invalid_peak["lifecycle"]["resources"]["threads"]["peak"] = 0
        self.assert_rejected(invalid_peak)

    def test_lifecycle_v2_is_bound_to_reference_and_derived_evidence(self):
        wrong_iterations = self.fixture.lifecycle_v2()
        wrong_iterations["lifecycle"]["iterations"]["createDestroy"]["value"] = 1
        self.assert_lifecycle_rejected(wrong_iterations, "predeclared iterations")

        invented_reason = self.fixture.lifecycle_v2()
        invented_reason["lifecycle"]["iterations"]["deviceLoss"]["reason"] = (
            "invented unsupported reason"
        )
        self.assert_lifecycle_rejected(invented_reason, "predeclared iterations")

        nonzero_endpoint = self.fixture.lifecycle_v2()
        nonzero_endpoint["lifecycle"]["resources"]["threads"]["after"] = 1
        self.assert_lifecycle_rejected(nonzero_endpoint, "resource verdict")

        false_resource_verdict = self.fixture.lifecycle_v2(gpu_available=False)
        false_resource_verdict["verdict"]["checks"]["resources"] = True
        false_resource_verdict["verdict"]["accepted"] = True
        self.assert_lifecycle_rejected(false_resource_verdict, "resource verdict")

        failed_assertion = self.fixture.lifecycle_v2()
        self.replace_lifecycle_evidence(
            failed_assertion,
            lambda evidence: evidence["iterations"][0]["stoppedLifecycle"].update(
                generationsCreated=1
            ),
        )
        self.assert_lifecycle_rejected(failed_assertion, "lifecycle verdict")

        invented_peak = self.fixture.lifecycle_v2()
        self.replace_lifecycle_evidence(
            invented_peak,
            lambda evidence: evidence["resourcePeaks"].update(threads=99),
        )
        self.assert_lifecycle_rejected(invented_peak, "derived resource peaks")

    def test_derived_artifact_relationship_and_digests_are_bound(self):
        workload_manifest, record = self.derived_artifact_case()
        contract.validate_result_against_manifest(
            record, workload_manifest, artifact_root=self.fixture.root
        )

        invalid_manifest = copy.deepcopy(workload_manifest)
        invalid_manifest["derivedArtifacts"][0]["generatorAsset"] = "unknown"
        with self.assertRaises(contract.ContractError):
            contract.validate_manifest(invalid_manifest)

        wrong_digest = copy.deepcopy(record)
        wrong_digest["correctness"]["generatedArtifacts"][0]["actualSha256"] = digest(
            "other"
        )
        self.assert_rejected(wrong_digest)

    def test_missing_or_tampered_derived_artifact_relationship_is_rejected(self):
        workload_manifest, record = self.derived_artifact_case()

        missing = copy.deepcopy(record)
        del missing["correctness"]["generatedArtifacts"]
        missing["artifacts"] = missing["artifacts"][:2]
        with self.assertRaisesRegex(contract.ContractError, "relationships"):
            contract.validate_result_against_manifest(missing, workload_manifest)

        tampered = copy.deepcopy(record)
        generated = tampered["correctness"]["generatedArtifacts"][0]
        generated["artifact"] = "frame"
        generated["actualSha256"] = self.fixture.frame["sha256"]
        tampered["artifacts"] = [
            artifact
            for artifact in tampered["artifacts"]
            if artifact["name"] != "generated-media-container"
        ]
        with self.assertRaisesRegex(contract.ContractError, "relationships"):
            contract.validate_result_against_manifest(tampered, workload_manifest)

    def test_canonical_hash_and_atomic_record_write_are_deterministic(self):
        record = self.fixture.correctness(full=True)
        reordered = json.loads(json.dumps(record))
        reordered = dict(reversed(list(reordered.items())))
        self.assertEqual(contract.canonical_hash(record), contract.canonical_hash(reordered))
        first = contract.write_record(record, manifest(), self.fixture.root)
        second = contract.write_record(reordered, manifest(), self.fixture.root)
        self.assertEqual(first, second)
        self.assertFalse(first.is_symlink())
        self.assertEqual(first.read_bytes(), contract.canonical_json_bytes(record))

        changed_manifest = manifest()
        changed_manifest["seed"] = 8
        with self.assertRaises(contract.ContractError):
            contract.validate_result_against_manifest(record, changed_manifest)

    def test_manifest_reference_checkpoint_and_invariant_binding(self):
        workload_manifest = manifest()
        record = self.fixture.correctness()

        wrong_reference = copy.deepcopy(record)
        wrong_reference["correctness"]["reference"]["sha256"] = digest("other")
        with self.assertRaises(contract.ContractError):
            contract.validate_result_against_manifest(
                wrong_reference, workload_manifest
            )

        wrong_checkpoint = copy.deepcopy(record)
        wrong_checkpoint["correctness"]["checkpoints"][0]["identity"] = "invented"
        with self.assertRaises(contract.ContractError):
            contract.validate_result_against_manifest(
                wrong_checkpoint, workload_manifest
            )

        wrong_association = copy.deepcopy(record)
        wrong_association["correctness"]["checkpoints"][0]["invariants"] = [
            "invented"
        ]
        with self.assertRaises(contract.ContractError):
            contract.validate_result_against_manifest(
                wrong_association, workload_manifest
            )

        missing_assertion = copy.deepcopy(record)
        missing_assertion["correctness"]["semanticAssertions"] = []
        with self.assertRaises(contract.ContractError):
            contract.validate_result_against_manifest(
                missing_assertion, workload_manifest
            )

        duplicate_association = manifest()
        duplicate_association["checkpoints"][0]["invariants"].append(
            "frame-matches"
        )
        with self.assertRaises(contract.ContractError):
            contract.validate_manifest(duplicate_association)

        ordered_manifest = manifest()
        ordered_manifest["invariants"].append(
            {"identity": "second-invariant", "description": "Second invariant."}
        )
        ordered_manifest["checkpoints"].append(
            {
                "identity": "second-frame",
                "atNanoseconds": 1,
                "invariants": ["second-invariant"],
            }
        )
        ordered_record = self.fixture.correctness()
        ordered_record["run"]["manifestSha256"] = contract.manifest_hash(
            ordered_manifest
        )
        ordered_record["correctness"]["checkpoints"].append(
            {
                "identity": "second-frame",
                "invariants": ["second-invariant"],
                "passed": True,
                "artifact": "frame",
            }
        )
        ordered_record["correctness"]["semanticAssertions"].append(
            {
                "identity": "second-invariant",
                "passed": True,
                "artifact": "frame",
            }
        )
        contract.validate_result_against_manifest(ordered_record, ordered_manifest)
        ordered_record["correctness"]["checkpoints"].reverse()
        with self.assertRaises(contract.ContractError):
            contract.validate_result_against_manifest(
                ordered_record, ordered_manifest
            )

    def test_tampered_artifact_is_rejected_without_source_mutation(self):
        record = self.fixture.correctness()
        source_before = self.fixture.frame_source.read_bytes()
        artifact = self.fixture.root / self.fixture.frame["path"]
        artifact.write_bytes(b"tampered")
        with self.assertRaises(contract.ContractError):
            contract.verify_artifacts(record, self.fixture.root)
        self.assertEqual(self.fixture.frame_source.read_bytes(), source_before)

    def test_missing_and_unavailable_required_evidence_are_rejected(self):
        missing = self.fixture.correctness()
        del missing["execution"]["presents"]
        self.assert_rejected(missing)
        unavailable = self.fixture.correctness()
        unavailable["execution"]["presents"] = {
            "status": "unavailable",
            "reason": "synthetic absence",
        }
        self.assert_rejected(unavailable)
        lifecycle = self.fixture.lifecycle()
        lifecycle["lifecycle"]["leakEvidence"]["status"] = "unavailable"
        self.assert_rejected(lifecycle)

    def test_purpose_contamination_and_contradictory_verdict_are_rejected(self):
        contaminated = self.fixture.correctness()
        contaminated["profile"] = {
            "valid": True,
            "invalidReasons": [],
            "trialOrder": ["synthetic"],
            "rawArtifacts": ["frame"],
        }
        self.assert_rejected(contaminated)
        contradictory = self.fixture.correctness()
        contradictory["verdict"]["failures"] = ["synthetic failure"]
        self.assert_rejected(contradictory)
        failed_assertion = self.fixture.correctness()
        failed_assertion["correctness"]["semanticAssertions"][0]["passed"] = False
        self.assert_rejected(failed_assertion)

    def test_verdict_categories_match_evidence_for_rejected_records(self):
        graphics_error = reject_record(self.fixture.correctness())
        graphics_error["correctness"]["graphicsErrors"] = available(1)
        self.assert_rejected(graphics_error)
        graphics_error["verdict"]["checks"]["correctness"] = False
        contract.validate_result(graphics_error)

        shader_error = reject_record(self.fixture.correctness())
        shader_error["shaders"]["diagnostics"] = [
            {
                "severity": "error",
                "code": "synthetic-error",
                "message": "Synthetic shader error.",
            }
        ]
        self.assert_rejected(shader_error)
        shader_error["verdict"]["checks"]["diagnostics"] = False
        contract.validate_result(shader_error)

        leaks = reject_record(self.fixture.lifecycle())
        leaks["lifecycle"]["leakEvidence"]["status"] = "leaks"
        self.assert_rejected(leaks)
        leaks["verdict"]["checks"]["leaks"] = False
        contract.validate_result(leaks)

    def test_lifecycle_process_manifest_is_one_anchored_tree(self):
        wrong_root = self.fixture.lifecycle(full=True)
        wrong_root["lifecycle"]["processManifest"][0]["role"] = "driver"
        wrong_root["lifecycle"]["processManifest"][1]["parentRole"] = "driver"
        self.assert_rejected(wrong_root)

        wrong_hash = self.fixture.lifecycle()
        wrong_hash["lifecycle"]["processManifest"][0]["executableSha256"] = digest(
            "other"
        )
        self.assert_rejected(wrong_hash)

        multiple_roots = self.fixture.lifecycle(full=True)
        multiple_roots["lifecycle"]["processManifest"][1]["parentRole"] = None
        self.assert_rejected(multiple_roots)

        cycle = self.fixture.lifecycle(full=True)
        cycle["lifecycle"]["processManifest"].extend(
            [
                {
                    "role": "cycle-a",
                    "executableSha256": digest("a"),
                    "parentRole": "cycle-b",
                },
                {
                    "role": "cycle-b",
                    "executableSha256": digest("b"),
                    "parentRole": "cycle-a",
                },
            ]
        )
        self.assert_rejected(cycle)

    def test_artifact_inventory_is_complete_and_cas_aliases_are_allowed(self):
        record = self.fixture.correctness()
        unused = contract.ingest_artifact(
            self.fixture.leak_source,
            self.fixture.root,
            "unused",
            "text/plain",
        )
        record["artifacts"].append(unused)
        self.assert_rejected(record)

        alias = contract.ingest_artifact(
            self.fixture.build_source,
            self.fixture.root,
            "build-log-alias",
            "text/plain",
        )
        self.assertEqual(alias["path"], self.fixture.build["path"])
        aliased = self.fixture.correctness()
        aliased["artifacts"].append(alias)
        aliased["build"]["artifacts"].append("build-log-alias")
        contract.validate_result(aliased, artifact_root=self.fixture.root)

    def test_unknown_result_fields_workloads_and_forward_versions_are_rejected(self):
        extra = self.fixture.correctness()
        extra["host"]["brightness"] = 50
        self.assert_rejected(extra)
        workload = self.fixture.correctness()
        workload["run"]["workload"]["identity"] = "unknown"
        self.assert_rejected(workload)
        forward = self.fixture.correctness()
        forward["schemaVersion"] = 2
        self.assert_rejected(forward)
        purpose = self.fixture.correctness()
        purpose["run"]["purpose"] = "benchmark"
        self.assert_rejected(purpose)

    def test_malformed_hashes_times_and_counts_are_rejected(self):
        bad_hash = self.fixture.correctness()
        bad_hash["run"]["sourceSha256"] = "ABC"
        self.assert_rejected(bad_hash)
        bad_time = self.fixture.correctness()
        bad_time["run"]["completedAtUtc"] = "2026-07-22T07:59:59Z"
        self.assert_rejected(bad_time)
        bad_count = self.fixture.correctness()
        bad_count["execution"]["presents"] = available(True)
        self.assert_rejected(bad_count)

    def test_traversal_absolute_paths_and_symlinks_are_rejected(self):
        traversal = self.fixture.correctness()
        traversal["artifacts"][0]["path"] = "../build.log"
        self.assert_rejected(traversal)
        absolute = self.fixture.correctness()
        absolute["build"]["commands"] = ["cmake --build /Users/person/build"]
        self.assert_rejected(absolute)

        source_link = self.fixture.root / "source-link"
        source_link.symlink_to(self.fixture.build_source)
        with self.assertRaises(contract.ContractError):
            contract.ingest_artifact(
                source_link, self.fixture.root, "linked", "text/plain"
            )

        linked_store = self.fixture.root / "linked-store"
        linked_store.mkdir()
        (linked_store / "artifacts").symlink_to(self.fixture.root / "artifacts")
        with self.assertRaises(contract.ContractError):
            contract.verify_artifacts(self.fixture.correctness(), linked_store)

        artifact = self.fixture.root / self.fixture.frame["path"]
        artifact.unlink()
        artifact.symlink_to(self.fixture.frame_source)
        with self.assertRaises(contract.ContractError):
            contract.verify_artifacts(self.fixture.correctness(), self.fixture.root)

    def test_ancestor_symlinks_source_mutation_and_cas_collision_are_rejected(self):
        real_source_directory = self.fixture.root / "real-source"
        real_source_directory.mkdir()
        real_source = real_source_directory / "source.bin"
        real_source.write_bytes(b"source")
        source_parent_link = self.fixture.root / "source-parent-link"
        source_parent_link.symlink_to(real_source_directory)
        with self.assertRaises(contract.ContractError):
            contract.ingest_artifact(
                source_parent_link / "source.bin",
                self.fixture.root,
                "ancestor-linked-source",
                "application/octet-stream",
            )

        store_parent_link = self.fixture.root / "store-parent-link"
        store_parent_link.symlink_to(self.fixture.root)
        with self.assertRaises(contract.ContractError):
            contract.ingest_artifact(
                real_source,
                store_parent_link,
                "ancestor-linked-store",
                "application/octet-stream",
            )

        mutable_source = self.fixture.root / "mutable.bin"
        mutable_source.write_bytes(b"before")
        with self.assertRaises(contract.ContractError):
            contract.ingest_artifact(
                mutable_source,
                self.fixture.root,
                "mutable",
                "application/octet-stream",
                _test_hook=lambda: mutable_source.write_bytes(b"after-change"),
            )
        self.assertFalse(
            any(
                path.name.startswith(".ingest-")
                for path in (self.fixture.root / "artifacts" / "sha256").iterdir()
            )
        )

        collision_source = self.fixture.root / "collision.bin"
        collision_source.write_bytes(b"collision-source")
        collision_digest = hashlib.sha256(b"collision-source").hexdigest()
        collision_directory = (
            self.fixture.root / "artifacts" / "sha256" / collision_digest[:2]
        )
        collision_directory.mkdir(exist_ok=True)
        collision_target = collision_directory / collision_digest
        collision_target.write_bytes(b"unsafe-existing-content")
        with self.assertRaises(contract.ContractError):
            contract.ingest_artifact(
                collision_source,
                self.fixture.root,
                "collision",
                "application/octet-stream",
            )
        self.assertEqual(collision_target.read_bytes(), b"unsafe-existing-content")

    def test_partial_artifact_and_record_writes_are_cleaned_up(self):
        new_source = self.fixture.root / "sources" / "new.log"
        new_source.write_bytes(b"new artifact")
        with mock.patch.object(contract.os, "link", side_effect=OSError("injected")):
            with self.assertRaises(OSError):
                contract.ingest_artifact(
                    new_source, self.fixture.root, "new-log", "text/plain"
                )
        ingest_temps = list((self.fixture.root / "artifacts").rglob(".ingest-*"))
        self.assertEqual(ingest_temps, [])
        self.assertEqual(new_source.read_bytes(), b"new artifact")

        record = self.fixture.correctness()
        with mock.patch.object(contract.os, "link", side_effect=OSError("injected")):
            with self.assertRaises(OSError):
                contract.write_record(record, manifest(), self.fixture.root)
        self.assertEqual(list((self.fixture.root / "records").glob(".record-*")), [])

    def test_exceptional_storage_paths_do_not_leak_descriptors(self):
        missing_store = self.fixture.root / "missing-store"
        self.assert_fd_count_stable(
            lambda: contract.ingest_artifact(
                self.fixture.build_source,
                missing_store,
                "missing-store",
                "text/plain",
            )
        )
        self.assertFalse(missing_store.exists())

        unsafe_store = self.fixture.root / "unsafe-store"
        unsafe_store.symlink_to(self.fixture.root)
        self.assert_fd_count_stable(
            lambda: contract.ingest_artifact(
                self.fixture.build_source,
                unsafe_store,
                "unsafe-store",
                "text/plain",
            )
        )

        missing_source = self.fixture.root / "missing-source"
        self.assert_fd_count_stable(
            lambda: contract.ingest_artifact(
                missing_source,
                self.fixture.root,
                "missing-source",
                "text/plain",
            )
        )

        unsafe_cas_store = self.fixture.root / "unsafe-cas-store"
        unsafe_sha_directory = unsafe_cas_store / "artifacts" / "sha256"
        unsafe_sha_directory.parent.mkdir(parents=True)
        unsafe_sha_directory.symlink_to(
            self.fixture.root / "artifacts" / "sha256"
        )
        self.assert_fd_count_stable(
            lambda: contract.verify_artifacts(
                self.fixture.correctness(), unsafe_cas_store
            )
        )

        records = self.fixture.root / "records"
        records.symlink_to(self.fixture.root / "artifacts")
        record = self.fixture.correctness()
        self.assert_fd_count_stable(
            lambda: contract.write_record(record, manifest(), self.fixture.root)
        )
        records.unlink()
        records.mkdir()

        with mock.patch.object(
            contract, "_open_private_file", side_effect=OSError("injected")
        ):
            self.assert_fd_count_stable(
                lambda: contract.ingest_artifact(
                    self.fixture.build_source,
                    self.fixture.root,
                    "temp-open",
                    "text/plain",
                ),
                OSError,
            )
            self.assert_fd_count_stable(
                lambda: contract.write_record(record, manifest(), self.fixture.root),
                OSError,
            )
        self.assertEqual(list(records.glob(".record-*")), [])
        self.assertEqual(
            list((self.fixture.root / "artifacts").rglob(".ingest-*")), []
        )

    def test_profiling_subagent_role_is_rejected(self):
        # Profiling records are no longer reserved (result version 3), but a
        # subagent still cannot produce one. Full profiling-record validation
        # lives in test_profiling.py; this pins the run-level invariant.
        run = self.fixture.correctness()["run"]
        run["purpose"] = "profiling"
        run["agentRole"] = "subagent"
        with self.assertRaisesRegex(contract.ContractError, "subagents cannot"):
            contract._validate_run(run)


if __name__ == "__main__":
    unittest.main()
