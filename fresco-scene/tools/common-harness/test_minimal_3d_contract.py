#!/usr/bin/env python3

import copy
import hashlib
import pathlib
import struct
import unittest

import contract
import minimal_3d_contract


class Minimal3DContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = pathlib.Path(__file__).with_name("workloads") / "minimal-3d"
        _, cls.fixture, cls.trace, cls.reference = (
            minimal_3d_contract.validate_directory(cls.root)
        )

    def values(self):
        return (
            copy.deepcopy(self.fixture),
            copy.deepcopy(self.trace),
            copy.deepcopy(self.reference),
        )

    def assert_rejected(self, mutate):
        fixture, trace, reference = self.values()
        mutate(fixture, trace, reference)
        with self.assertRaises(contract.ContractError):
            minimal_3d_contract.validate_values(fixture, trace, reference)

    def test_versioned_directory_is_self_consistent(self):
        manifest, fixture, trace, reference = (
            minimal_3d_contract.validate_directory(self.root)
        )
        self.assertEqual(manifest["workload"]["identity"], "minimal-3d")
        self.assertEqual(fixture["logicalConstantBinding"]["byteLength"], 64)
        self.assertEqual(trace["depthFormatResolution"]["status"], "resolved")
        self.assertEqual(trace["depthFormatResolution"]["selectedFormat"], "depth32float")
        self.assertEqual(reference["pixelOracle"]["status"], "ready")

    def test_logical_constant_is_not_a_mandatory_buffer_resource(self):
        self.assert_rejected(
            lambda fixture, trace, reference: trace["drawContract"][
                "logicalConstantBinding"
            ].update(buffer="uniform-buffer")
        )

    def test_coordinate_spaces_and_uv_edge_origin_are_independent(self):
        self.assert_rejected(
            lambda fixture, trace, reference: trace["drawContract"].update(
                frontFaceCoordinateSpace="ndc"
            )
        )
        self.assert_rejected(
            lambda fixture, trace, reference: fixture["coordinateConvention"][
                "texture"
            ].update(origin="top-left-texel-center")
        )

    def test_indices_must_remain_nonsequential_shared_and_hash_bound(self):
        def sequential(fixture, trace, reference):
            geometry = fixture["geometry"]
            geometry["indices"] = sorted(geometry["indices"])
            raw = struct.pack("<57H", *geometry["indices"])
            geometry["indexBytesHex"] = raw.hex()
            geometry["indexSha256"] = hashlib.sha256(raw).hexdigest()
            for checkpoint in trace["checkpoints"]:
                checkpoint["issuedDrawEvidence"]["indexSha256"] = geometry[
                    "indexSha256"
                ]
            reference["indexSensitivity"]["indexSha256"] = geometry[
                "indexSha256"
            ]

        self.assert_rejected(sequential)

        def erase_opposite_winding(fixture, trace, reference):
            geometry = fixture["geometry"]
            geometry["indices"][55], geometry["indices"][56] = (
                geometry["indices"][56], geometry["indices"][55]
            )
            raw = struct.pack("<57H", *geometry["indices"])
            geometry["indexBytesHex"] = raw.hex()
            geometry["indexSha256"] = hashlib.sha256(raw).hexdigest()
            for checkpoint in trace["checkpoints"]:
                checkpoint["issuedDrawEvidence"]["indexSha256"] = geometry[
                    "indexSha256"
                ]
            reference["indexSensitivity"]["indexSha256"] = geometry[
                "indexSha256"
            ]

        self.assert_rejected(erase_opposite_winding)

    def test_depth_far_cull_and_perspective_evidence_cannot_alias(self):
        def overlap_far(fixture, trace, reference):
            probes = {item["identity"]: item for item in reference["probes"]}
            probes["far-nonoverlap-visible"]["normalizedMilliRect"] = list(
                probes["depth-overlap-near"]["normalizedMilliRect"]
            )

        self.assert_rejected(overlap_far)

        def overlap_perspective(fixture, trace, reference):
            probes = {item["identity"]: item for item in reference["probes"]}
            probes["perspective-near-extent"]["normalizedMilliRect"] = list(
                probes["depth-overlap-near"]["normalizedMilliRect"]
            )

        self.assert_rejected(overlap_perspective)

        self.assert_rejected(
            lambda fixture, trace, reference: trace["checkpoints"][0].update(
                transform="landscape-t1"
            )
        )
        self.assert_rejected(
            lambda fixture, trace, reference: trace["checkpoints"][1][
                "issuedDrawEvidence"
            ].update(indexed=False)
        )

    def test_index_mutations_are_exact_and_analytically_bound(self):
        def unchanged(fixture, trace, reference):
            mutation = reference["indexSensitivity"]["mutations"][0]
            mutation["replacement"] = fixture["geometry"]["indices"][
                mutation["indexOrdinal"]
            ]

        self.assert_rejected(unchanged)
        self.assert_rejected(
            lambda fixture, trace, reference: reference["indexSensitivity"][
                "mutations"
            ][0].update(targetProbe="invented-probe")
        )

    def test_model_and_resolved_bytes_cannot_contradict(self):
        self.assert_rejected(
            lambda fixture, trace, reference: fixture["transforms"][0][
                "modelMatrixColumnMajor"
            ].__setitem__(12, 0.25)
        )

    def test_expected_roles_and_perspective_evidence_are_exact(self):
        self.assert_rejected(
            lambda fixture, trace, reference: reference["probes"][2][
                "expectedRoles"
            ].__setitem__("cull-back-landscape-t0", "cull-diagnostic")
        )

        def delete_perspective_evidence(fixture, trace, reference):
            assertion = next(
                item for item in reference["assertions"]
                if item["identity"] == "perspective-foreshortening"
            )
            assertion["evidence"].remove("frozen-projected-bounds")

        self.assert_rejected(delete_perspective_evidence)

    def test_unknown_critical_schema_fields_are_rejected(self):
        self.assert_rejected(
            lambda fixture, trace, reference: trace["drawContract"].update(
                metalFlipY=True
            )
        )
        self.assert_rejected(
            lambda fixture, trace, reference: trace["checkpoints"][0][
                "issuedDrawEvidence"
            ].update(resourceId="candidate-private")
        )
        self.assert_rejected(
            lambda fixture, trace, reference: reference["probes"][0].update(
                expectedRole="cube-near"
            )
        )

    def test_checkpoint_semantics_are_frozen_per_identity(self):
        self.assert_rejected(
            lambda fixture, trace, reference: trace["checkpoints"][2].update(
                transform="landscape-t0"
            )
        )
        self.assert_rejected(
            lambda fixture, trace, reference: trace["checkpoints"][0].update(
                geometryState="candidate-private-geometry"
            )
        )
        self.assert_rejected(
            lambda fixture, trace, reference: trace["checkpoints"][1].update(
                rasterCullMode="none"
            )
        )

        def move_assertion(fixture, trace, reference):
            assertion = trace["checkpoints"][1]["assertions"].pop(1)
            trace["checkpoints"][2]["assertions"].append(assertion)

        self.assert_rejected(move_assertion)

    def test_teardown_requirements_are_exact(self):
        self.assert_rejected(
            lambda fixture, trace, reference: trace["teardown"].update(
                requires=[]
            )
        )

    def test_depth_format_resolution_is_bound_to_candidate_evidence(self):
        self.assert_rejected(
            lambda fixture, trace, reference: trace["depthFormatResolution"][
                "evidence"
            ]["support"].__setitem__("depth32float", False)
        )
        self.assert_rejected(
            lambda fixture, trace, reference: trace["depthFormatResolution"][
                "evidence"
            ].__setitem__("sdlVersion", "unmeasured")
        )
        self.assert_rejected(
            lambda fixture, trace, reference: reference["pixelOracle"].update(
                referenceSet="unmeasured-reference.json"
            )
        )


if __name__ == "__main__":
    unittest.main()
