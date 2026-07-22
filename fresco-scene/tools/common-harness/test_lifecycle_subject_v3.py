#!/usr/bin/env python3

import copy
import json
import pathlib
import unittest
from unittest import mock

import contract
import lifecycle_subject_v3 as subject


def raw(role, reference):
    assignment = f"synthetic-{role}"
    endpoint = dict(reference["endpoints"][role])
    balance = endpoint.pop("programPublicationDeletionBalance")
    endpoint["programPublications"] = 1 if balance else 2
    endpoint["programDeletions"] = 1
    types = ["hello", "ready", "stopped"] if role == "control" else ["hello", "ready", "ready", "stopped"]
    lines = []
    for event_type in types:
        event = {"assignmentID": assignment, "type": event_type}
        if event_type == "stopped":
            event["renderResourceLifecycle"] = endpoint
            event["renderAllocations"] = {}
        lines.append(json.dumps(event, separators=(",", ":")))
    lines.append("Process 123: 0 leaks for 0 total leaked bytes.")
    return assignment, {
        "commands": [], "exitStatus": 0, "timedOut": False,
        "stdout": "\n".join(lines) + "\n", "stderr": "",
    }


def run(role, ordinal, reference):
    assignment, report = raw(role, reference)
    derived, invalid = subject.derive(report, assignment, role, reference)
    return {
        "ordinal": ordinal, "backend": "native-opengl", "role": role,
        "attempt": 1, "assignment": assignment, "elapsedNanoseconds": 1,
        "status": "valid" if not invalid else "invalid",
        "invalidReasons": invalid, "rawReport": report, "derived": derived,
    }


class SubjectLifecycleV3Test(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.reference = contract.load_json(subject.ROOT / subject.REFERENCE_FILE)
        cls.trace = contract.load_json(subject.ROOT / subject.TRACE_FILE)

    def campaign(self):
        runs = [run(role, ordinal, self.reference) for ordinal, role in enumerate(self.trace["slotOrder"], 1)]
        return {
            "slotOrder": list(self.trace["slotOrder"]), "runs": runs,
            "runReceipts": [{} for _ in runs], "invalidRuns": [],
            "campaignStatus": "accepted",
        }

    def test_valid_campaign_and_cap_drift(self):
        subject.validate_campaign(self.campaign(), self.reference, self.trace)
        changed = copy.deepcopy(self.reference)
        changed["absoluteCaps"]["rawLeakObjects"] = -1
        _, report = raw("subject", changed)
        _derived, invalid = subject.derive(report, "synthetic-subject", "subject", changed)
        self.assertIn("absolute-cap-rawLeakObjects", invalid)

    def test_addendum_drift_is_rejected(self):
        real_identity = subject.identity
        addendum = subject.ROOT / "lifecycle-control-calibration-archive-addendum-v4.json"
        def drift(path):
            value = real_identity(path)
            return {**value, "bytes": value["bytes"] + 1} if pathlib.Path(path) == addendum else value
        with mock.patch.object(subject, "identity", side_effect=drift):
            with self.assertRaisesRegex(subject.SubjectError, "archiveAddendumV4"):
                subject.load_material()

    def test_order_retry_and_omission_are_rejected(self):
        campaign = self.campaign()
        campaign["runs"][0], campaign["runs"][1] = campaign["runs"][1], campaign["runs"][0]
        with self.assertRaises(subject.SubjectError): subject.validate_campaign(campaign, self.reference, self.trace)
        campaign = self.campaign(); campaign["runs"][0]["attempt"] = 2
        with self.assertRaisesRegex(subject.SubjectError, "retry"): subject.validate_campaign(campaign, self.reference, self.trace)
        campaign = self.campaign(); campaign["runs"].pop(); campaign["runReceipts"].pop()
        with self.assertRaisesRegex(subject.SubjectError, "omitted"): subject.validate_campaign(campaign, self.reference, self.trace)

    def test_control_and_subject_failure_reject(self):
        for ordinal in (1, 2):
            campaign = self.campaign()
            item = campaign["runs"][ordinal - 1]
            item["rawReport"]["timedOut"] = True
            item["derived"], item["invalidReasons"] = subject.derive(item["rawReport"], item["assignment"], item["role"], self.reference)
            item["status"] = "invalid"
            campaign["invalidRuns"] = [ordinal]
            campaign["campaignStatus"] = "rejected"
            with self.assertRaises(subject.SubjectError): subject.validate_campaign(campaign, self.reference, self.trace)
            subject.validate_campaign(campaign, self.reference, self.trace, complete=False)

    def test_attribution_and_endpoint_failure(self):
        assignment, report = raw("subject", self.reference)
        report["stdout"] += "STACK OF 1 INSTANCE OF FrescoScene mystery:\n0 foo\n====\n"
        _derived, invalid = subject.derive(report, assignment, "subject", self.reference)
        self.assertIn("group-1-forbidden-frame", invalid)
        assignment, report = raw("subject", self.reference)
        report["stdout"] = report["stdout"].replace('"liveGenerations":0', '"liveGenerations":1')
        _derived, invalid = subject.derive(report, assignment, "subject", self.reference)
        self.assertIn("renderer-lifecycle-endpoint", invalid)

    def test_verdict_inconsistency_is_rejected(self):
        campaign = self.campaign(); campaign["runs"][0]["status"] = "invalid"
        with self.assertRaisesRegex(subject.SubjectError, "verdict inconsistent"):
            subject.validate_campaign(campaign, self.reference, self.trace)


if __name__ == "__main__":
    unittest.main()
