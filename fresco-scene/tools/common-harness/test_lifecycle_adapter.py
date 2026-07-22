#!/usr/bin/env python3

import copy
import hashlib
import pathlib
import re
import unittest

import adapter
import contract
import lifecycle_adapter


class LifecycleAdapterTest(unittest.TestCase):
    def setUp(self):
        self.required = {
            "generationsPerIteration": 2,
            "completionBarriersPerIteration": 2,
            "liveGenerationsAfterStop": 0,
            "programPublicationDeletionBalance": True,
        }
        self.stopped = {
            "generationsCreated": 2,
            "generationsRetired": 2,
            "liveGenerations": 0,
            "completionBarriersCompleted": 2,
            "completionBarriersFailed": 0,
            "retirementsWithoutCompletion": 0,
            "programPublications": 8,
            "programDeletions": 8,
        }

    def test_programs_are_not_misstated_as_total_gpu_resources(self):
        event = {
            "programCacheEntries": 4,
            "renderAllocations": {
                "intermediateTextures": {"live": 2},
                "intermediateFramebuffers": {"live": 2},
            },
        }
        self.assertEqual(lifecycle_adapter._live_renderer_allocations(event), 4)
        self.assertEqual(event["programCacheEntries"], 4)

    def test_allocation_evidence_must_be_present_and_well_formed(self):
        for event in (
            {},
            {"renderAllocations": []},
            {"renderAllocations": {"textures": {"live": -1}}},
            {"renderAllocations": {"textures": {"live": "1"}}},
        ):
            with self.subTest(event=event):
                with self.assertRaises(adapter.AdapterError):
                    lifecycle_adapter._live_renderer_allocations(event)

    def test_each_predeclared_lifecycle_assertion_is_enforced(self):
        lifecycle_adapter._validate_stopped_lifecycle(
            self.stopped, self.required
        )
        mutations = {
            "generationsCreated": 1,
            "generationsRetired": 1,
            "liveGenerations": 1,
            "completionBarriersCompleted": 1,
            "completionBarriersFailed": 1,
            "retirementsWithoutCompletion": 1,
            "programDeletions": 7,
        }
        for field, value in mutations.items():
            altered = {**self.stopped, field: value}
            with self.subTest(field=field):
                with self.assertRaises(adapter.AdapterError):
                    lifecycle_adapter._validate_stopped_lifecycle(
                        altered, self.required
                    )

    def test_resource_verdict_is_derived_from_endpoint_and_peak_criteria(self):
        criteria = {
            "threads": {"before": 0, "after": 0, "peakAtLeast": 1}
        }
        sample = {
            "threads": {
                "status": "available", "before": 0, "after": 0, "peak": 2,
            }
        }
        self.assertTrue(
            lifecycle_adapter._resource_criteria_passed(sample, criteria)
        )
        sample["threads"]["after"] = 1
        self.assertFalse(
            lifecycle_adapter._resource_criteria_passed(sample, criteria)
        )

    def matched_control_case(self):
        reference = contract.load_json(
            pathlib.Path(__file__).with_name("workloads")
            / "resource-reload"
            / "lifecycle-reference-v2.json"
        )
        criteria = reference["leakCriteria"]

        def report(assignment, stacks, count=3, leaked_bytes=192):
            stdout = "\n".join(
                f"STACK OF 1 INSTANCE OF 'ROOT LEAK: synthetic-{index}':\n"
                f"Call stack: {stack}\n===="
                for index, stack in enumerate(stacks, 1)
            )
            stdout += (
                f"\nProcess 1: {count} leaks for {leaked_bytes} total leaked bytes."
            )
            value = {
                "assignment": assignment,
                "loadCount": 1,
                "eventTypes": ["hello", "ready", "stopped"],
                "leakCount": count,
                "leakedBytes": leaked_bytes,
                "stdout": stdout,
            }
            value["normalization"] = lifecycle_adapter._normalized_leak_evidence(
                value, criteria
            )
            return value

        subject = report(
            "lifecycle-at-exit-leak-check",
            ["AppIntents", "LinkServices", "NSXPCConnection"],
        )
        control = report(
            "lifecycle-appkit-window-control",
            ["AppIntents", "LinkServices", "NSXPCConnection"],
        )
        return criteria, subject, control

    def test_matched_control_leak_criterion_accepts_only_the_frozen_relation(self):
        criteria, subject, control = self.matched_control_case()
        self.assertTrue(
            lifecycle_adapter._matched_control_leaks_passed(
                subject, control, criteria
            )
        )

        cases = {}
        cases["protocol"] = copy.deepcopy((subject, control))
        cases["protocol"][1]["eventTypes"] = ["hello", "stopped"]
        cases["missing-control-signature"] = copy.deepcopy((subject, control))
        cases["missing-control-signature"][1]["normalization"][
            "normalizedSignatures"
        ].remove("apple-linkservices")
        cases["extra-subject-signature"] = copy.deepcopy((subject, control))
        cases["extra-subject-signature"][0]["normalization"][
            "normalizedSignatures"
        ].append("candidate-private")
        cases["subject-object-excess"] = copy.deepcopy((subject, control))
        cases["subject-object-excess"][0]["leakCount"] = 4
        cases["subject-byte-excess"] = copy.deepcopy((subject, control))
        cases["subject-byte-excess"][0]["leakedBytes"] = 193

        for identity, (altered_subject, altered_control) in cases.items():
            with self.subTest(identity=identity):
                self.assertFalse(
                    lifecycle_adapter._matched_control_leaks_passed(
                        altered_subject, altered_control, criteria
                    )
                )

    def test_normalization_exposes_unknown_and_renderer_attributable_groups(self):
        criteria, subject, control = self.matched_control_case()
        subject["stdout"] = subject["stdout"].replace(
            "Call stack: AppIntents", "Call stack: AppIntents FrescoScene OpenGL"
        )
        subject["normalization"] = lifecycle_adapter._normalized_leak_evidence(
            subject, criteria
        )
        self.assertEqual(
            subject["normalization"]["forbiddenAttributionGroupCount"], 1
        )
        self.assertFalse(
            lifecycle_adapter._matched_control_leaks_passed(
                subject, control, criteria
            )
        )

        subject["stdout"] = subject["stdout"].replace(
            "Call stack: LinkServices", "Call stack: UnknownFramework"
        )
        subject["normalization"] = lifecycle_adapter._normalized_leak_evidence(
            subject, criteria
        )
        self.assertEqual(subject["normalization"]["unknownGroupCount"], 1)
        self.assertFalse(
            lifecycle_adapter._matched_control_leaks_passed(
                subject, control, criteria
            )
        )

    def test_complete_stack_hash_is_bound_by_normalization(self):
        criteria, subject, _control = self.matched_control_case()
        group = subject["normalization"]["groups"][0]
        first_heading = lifecycle_adapter.LEAK_STACK_HEADING.search(
            subject["stdout"]
        )
        delimiter = re.search(
            r"(?m)^====\s*$", subject["stdout"][first_heading.end():]
        )
        end = first_heading.end() + delimiter.end()
        stack = subject["stdout"][first_heading.start():end]
        stack = stack.rstrip() + "\n"
        self.assertEqual(
            group["stackSha256"], hashlib.sha256(stack.encode()).hexdigest()
        )


if __name__ == "__main__":
    unittest.main()
