#!/usr/bin/env python3

import copy
import json
import unittest

import lifecycle_control_calibration as calibration


class LifecycleControlCalibrationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _path, cls.plan, cls.plan_identity = calibration._load_plan()

    def raw_report(self, assignment, instances=2, heading="NSXPCConnection"):
        stopped = {
            "protocolVersion": 1,
            "type": "stopped",
            "assignmentID": assignment,
            "renderResourceLifecycle": {
                "liveGenerations": 0,
                "completionBarriersFailed": 0,
                "retirementsWithoutCompletion": 0,
                "programPublications": 1,
                "programDeletions": 1,
            },
        }
        events = [
            {"protocolVersion": 1, "type": "hello", "assignmentID": assignment},
            {"protocolVersion": 1, "type": "ready", "assignmentID": assignment},
            stopped,
        ]
        objects, leaked_bytes = instances * 96, instances * 6272
        stdout = "\n".join(json.dumps(event) for event in events)
        stdout += (
            f"\nSTACK OF {instances} INSTANCES OF 'ROOT CYCLE: <{heading}>':\n"
            "1 com.apple.AppIntents synthetic\n"
            "0 com.apple.LinkServices +[NSXPCConnection synthetic]\n"
            "====\n"
            f"Process 1: {objects} leaks for {leaked_bytes} total leaked bytes."
        )
        commands = [
            {"protocolVersion": 1, "type": "hello", "assignmentID": assignment},
            {
                "protocolVersion": 1, "type": "load",
                "assignmentID": assignment, "path": "/synthetic/control",
            },
            {"protocolVersion": 1, "type": "stop", "assignmentID": assignment},
        ]
        return {
            "commands": commands,
            "exitStatus": 1,
            "timedOut": False,
            "stdout": stdout,
            "stderr": "",
        }

    def campaign(self):
        counts = {"native-opengl": 0, "angle-metal": 0}
        runs = []
        for ordinal, backend in enumerate(self.plan["frozenOrder"], 1):
            counts[backend] += 1
            assignment = f"calibration-v3-{ordinal:03d}-{backend}"
            raw = self.raw_report(assignment, 2 + ordinal % 2)
            derived, invalid = calibration._derive_attempt(
                raw, assignment, self.plan
            )
            runs.append({
                "ordinal": ordinal,
                "backend": backend,
                "attemptWithinBackend": counts[backend],
                "attempt": 1,
                "assignment": assignment,
                "elapsedNanoseconds": 1,
                "status": "valid",
                "invalidReasons": invalid,
                "rawReport": raw,
                "derived": derived,
            })
        return {
            "schemaVersion": 3,
            "identity": "resource-lifecycle-control-calibration-v3",
            "purpose": "control-only-calibration",
            "plan": copy.deepcopy(self.plan_identity),
            "host": {"osVersion": "1", "osBuild": "1A1", "architecture": "arm64"},
            "tool": {
                "identity": "macos-leaks", "version": "report-7",
                "sha256": "a" * 64, "bytes": 1,
            },
            "helpers": {
                backend: {
                    "candidate": backend,
                    "buildIdentity": f"build-{backend}",
                    "helperSha256": character * 64,
                    "helperBytes": 1,
                    "sourceManifestSha256": character * 64,
                    "sourceManifestBytes": 1,
                }
                for backend, character in (
                    ("native-opengl", "b"), ("angle-metal", "c")
                )
            },
            "frozenOrder": self.plan["frozenOrder"],
            "runs": runs,
            "campaignStatus": "valid",
            "invalidRuns": [],
            "derivedTable": calibration._derived_table(runs, self.plan),
        }

    def assert_rejected(self, mutate):
        campaign = self.campaign()
        mutate(campaign)
        with self.assertRaises(calibration.CalibrationError):
            calibration.validate_campaign(
                campaign, self.plan, self.plan_identity
            )

    def test_valid_campaign_derives_caps_from_all_frozen_controls(self):
        campaign = self.campaign()
        calibration.validate_campaign(campaign, self.plan, self.plan_identity)
        self.assertEqual(campaign["derivedTable"]["populationCount"], 40)
        self.assertEqual(campaign["derivedTable"]["maximumTotalRootInstances"], 3)

    def test_omission_reorder_and_selective_retry_are_rejected(self):
        self.assert_rejected(lambda campaign: campaign["runs"].pop())
        self.assert_rejected(
            lambda campaign: campaign["runs"].__setitem__(
                slice(0, 2), list(reversed(campaign["runs"][:2]))
            )
        )
        self.assert_rejected(
            lambda campaign: campaign["runs"][7].update(attempt=2)
        )

    def test_unknown_mixed_and_forbidden_groups_are_rejected(self):
        for heading in ("UnknownFramework", "AppIntents LinkServices"):
            def mutate(campaign, heading=heading):
                run = campaign["runs"][0]
                run["rawReport"] = self.raw_report(run["assignment"], heading=heading)
                derived, invalid = calibration._derive_attempt(
                    run["rawReport"], run["assignment"], self.plan
                )
                run.update(
                    derived=derived, invalidReasons=invalid, status="invalid"
                )
                campaign.update(
                    campaignStatus="invalid", invalidRuns=[1], derivedTable=None
                )

            self.assert_rejected(mutate)

        def forbidden(campaign):
            run = campaign["runs"][0]
            run["rawReport"]["stdout"] = run["rawReport"]["stdout"].replace(
                "1 com.apple.AppIntents synthetic",
                "1 com.apple.AppIntents FrescoScene OpenGL",
            )
            derived, invalid = calibration._derive_attempt(
                run["rawReport"], run["assignment"], self.plan
            )
            run.update(derived=derived, invalidReasons=invalid, status="invalid")
            campaign.update(
                campaignStatus="invalid", invalidRuns=[1], derivedTable=None
            )

        self.assert_rejected(forbidden)

    def test_forged_maxima_and_missing_raw_evidence_are_rejected(self):
        self.assert_rejected(
            lambda campaign: campaign["derivedTable"].update(
                maximumRawLeakObjects=999999
            )
        )
        self.assert_rejected(
            lambda campaign: campaign["runs"][0].update(rawReport=None)
        )

    def test_protocol_and_plan_binding_are_rejected_when_changed(self):
        self.assert_rejected(
            lambda campaign: campaign["runs"][0]["rawReport"]["commands"][1].update(
                assignmentID="retry"
            )
        )
        self.assert_rejected(
            lambda campaign: campaign["plan"].update(sha256="d" * 64)
        )


if __name__ == "__main__":
    unittest.main()
