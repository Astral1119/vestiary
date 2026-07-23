#!/usr/bin/env python3
"""Tests for the profiling evidence profile (result version 3) and the host/
power sampler. Correctness/lifecycle contract coverage lives in test_contract.py;
this file owns the profiling purpose and profiling_sampler."""

import copy
import plistlib
import tempfile
import unittest

import contract
import profiling_sampler as sampler
from test_contract import Fixture


def available(value):
    return {"available": True, "value": value}


UNAVAILABLE = {"available": False}


# --- sampler parsers ------------------------------------------------------


class SamplerParserTest(unittest.TestCase):
    def test_powermetrics_scoped_task_rollup(self):
        data = plistlib.dumps({
            "elapsed_ns": 201_000_000,
            "processor": {"cpu_power": 812.5, "gpu_power": 145.0},
            "gpu": {"idle_ratio": 0.87},
            "thermal_pressure": "Nominal",
            "tasks": [
                {"name": "fresco-scene", "pid": 13747,
                 "energy_impact": 4.2, "intr_wakeups": 30, "idle_wakeups": 5},
                {"name": "WindowServer", "pid": 200,
                 "energy_impact": 99.0, "intr_wakeups": 500},
            ],
        })
        parsed = sampler.parse_powermetrics_plist(data, target_pids={13747})
        self.assertEqual(parsed["cpuPowerMilliwatts"], available(812.5))
        self.assertAlmostEqual(parsed["gpuActiveResidency"]["value"], 0.13)
        self.assertEqual(parsed["thermalPressure"], available("Nominal"))
        rollup = parsed["tasks"]
        self.assertEqual(rollup["matchedProcesses"], 1)
        self.assertEqual(rollup["wakeups"], 35)
        self.assertAlmostEqual(rollup["energyImpact"], 4.2)

    def test_powermetrics_missing_keys_are_explicit_unavailable(self):
        parsed = sampler.parse_powermetrics_plist(plistlib.dumps({}))
        self.assertFalse(parsed["cpuPowerMilliwatts"]["available"])
        self.assertFalse(parsed["gpuPowerMilliwatts"]["available"])
        self.assertNotIn("value", parsed["cpuPowerMilliwatts"])

    def test_powermetrics_unparseable_is_reported(self):
        parsed = sampler.parse_powermetrics_plist(b"not a plist")
        self.assertIn("parseError", parsed)

    def test_pmset_accepts_both_low_power_key_spellings(self):
        modern = sampler.parse_pmset_power("Now drawing from 'AC Power'\n powermode 0")
        self.assertEqual(modern["powerSource"], available("AC Power"))
        self.assertEqual(modern["lowPowerMode"], available(False))
        legacy = sampler.parse_pmset_power("drawing from 'Battery Power'\n lowpowermode 1")
        self.assertEqual(legacy["lowPowerMode"], available(True))

    def test_vm_stat_converts_pages_to_bytes(self):
        text = ("Mach Virtual Memory Statistics: (page size of 16384 bytes)\n"
                "Pages free:     100.\nPages active:   200.\n")
        parsed = sampler.parse_vm_stat(text)
        self.assertEqual(parsed["pageSize"], 16384)
        self.assertEqual(parsed["bytes"]["free"], 100 * 16384)

    def test_ps_manifest_separates_tree_from_strays(self):
        text = ("PID PPID RSS COMM\n"
                "100 1 500 /bin/fresco-scene\n"       # candidate root
                "101 100 200 /bin/fresco-helper\n"    # descendant of candidate
                "200 1 300 /bin/fresco\n")            # unrelated fresco -> stray
        parsed = sampler.parse_ps_manifest(text, root_pids={100})
        self.assertEqual({p["pid"] for p in parsed["tree"]}, {100, 101})
        self.assertEqual([p["pid"] for p in parsed["strayFrescoProcesses"]], [200])


# --- profiling record schema (result version 3) ---------------------------


class ProfilingContractTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.fixture = Fixture(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def _record(self):
        base = self.fixture.correctness()
        return {
            "schemaVersion": 3,
            "run": {**base["run"], "purpose": "profiling"},
            "candidate": base["candidate"],
            "criteriaVersion": "profiling-v1",
            "build": base["build"],
            "host": base["host"],
            "display": base["display"],
            "policy": base["policy"],
            "profile": {
                "validity": True,
                "invalidReasons": [],
                "trialOrder": ["baseline-before", "candidate", "baseline-after"],
                "quiescenceManifest": {
                    "powerSource": available("AC Power"),
                    "lowPowerMode": available(False),
                    "thermalWarning": available(False),
                    "colorSpace": "sRGB",
                    "displayRefreshMilliHertz": 60000,
                    "ownershipClean": True,
                    "strayProcessCount": 0,
                },
                "metrics": {
                    "cpuPowerMilliwatts": available(812.5),
                    "gpuPowerMilliwatts": available(145.0),
                    "gpuActiveResidency": available(0.13),
                    "wakeups": available(35),
                    "contextSwitches": UNAVAILABLE,
                    "energyImpact": available(4.2),
                    "thermalPressure": available("Nominal"),
                    "memoryBytes": available(400_000_000),
                },
                "rawArtifacts": ["frame"],
            },
            "artifacts": [self.fixture.build, self.fixture.frame],
            "verdict": {
                "accepted": True,
                "criteriaVersion": "profiling-v1",
                "checks": {"build": True, "validity": True, "quiescence": True},
                "failures": [],
            },
        }

    def _invalidate(self, record, reasons):
        record["profile"]["validity"] = False
        record["profile"]["invalidReasons"] = reasons
        record["verdict"]["accepted"] = False
        record["verdict"]["checks"]["validity"] = False
        record["verdict"]["failures"] = list(reasons)

    def test_valid_profiling_record_accepts(self):
        self.assertIsNotNone(contract.validate_result(self._record()))

    def test_profiling_requires_result_version_3(self):
        record = self._record()
        record["schemaVersion"] = 1
        with self.assertRaisesRegex(contract.ContractError, "version 3"):
            contract.validate_result(record)

    def test_version_3_is_profiling_only(self):
        record = self.fixture.correctness()
        record["schemaVersion"] = 3
        with self.assertRaisesRegex(contract.ContractError, "profiling-only"):
            contract.validate_result(record)

    def test_subagent_cannot_produce_profiling_record(self):
        record = self._record()
        record["run"]["agentRole"] = "subagent"
        with self.assertRaisesRegex(contract.ContractError, "subagents cannot"):
            contract.validate_result(record)

    def test_valid_record_rejects_invalid_reasons(self):
        record = self._record()
        record["profile"]["invalidReasons"] = ["non-quiesced"]
        with self.assertRaisesRegex(contract.ContractError, "no invalid reasons"):
            contract.validate_result(record)

    def test_invalid_record_requires_a_reason(self):
        record = self._record()
        record["profile"]["validity"] = False
        record["verdict"]["checks"]["validity"] = False
        record["verdict"]["accepted"] = False
        with self.assertRaisesRegex(contract.ContractError, "must state a reason"):
            contract.validate_result(record)

    def test_unclean_ownership_cannot_be_valid(self):
        record = self._record()
        record["profile"]["quiescenceManifest"]["ownershipClean"] = False
        record["profile"]["quiescenceManifest"]["strayProcessCount"] = 3
        with self.assertRaisesRegex(contract.ContractError, "clean ownership"):
            contract.validate_result(record)

    def test_missing_required_metric_cannot_be_valid(self):
        record = self._record()
        record["profile"]["metrics"]["cpuPowerMilliwatts"] = UNAVAILABLE
        with self.assertRaisesRegex(contract.ContractError, "requires metrics"):
            contract.validate_result(record)

    def test_energy_impact_is_not_required(self):
        # Energy Impact is null on some macOS builds; a record is valid without it.
        record = self._record()
        record["profile"]["metrics"]["energyImpact"] = UNAVAILABLE
        self.assertIsNotNone(contract.validate_result(record))

    def test_dev_run_without_energy_accepts_as_invalid(self):
        # The dev-selftest shape: no sudo, strays present, marked invalid.
        record = self._record()
        record["profile"]["metrics"]["cpuPowerMilliwatts"] = UNAVAILABLE
        record["profile"]["metrics"]["gpuPowerMilliwatts"] = UNAVAILABLE
        record["profile"]["metrics"]["energyImpact"] = UNAVAILABLE
        record["profile"]["metrics"]["wakeups"] = UNAVAILABLE
        record["profile"]["quiescenceManifest"]["ownershipClean"] = False
        record["profile"]["quiescenceManifest"]["strayProcessCount"] = 3
        self._invalidate(record, ["dev-selftest", "energy-metrics-unavailable",
                                  "ownership-violation"])
        record["verdict"]["checks"]["quiescence"] = False
        self.assertIsNotNone(contract.validate_result(record))

    def test_verdict_validity_must_match_profile(self):
        record = self._record()
        record["verdict"]["checks"]["validity"] = False
        record["verdict"]["accepted"] = False
        record["verdict"]["failures"] = ["mismatch"]
        with self.assertRaisesRegex(contract.ContractError, "validity check contradicts"):
            contract.validate_result(record)

    def test_availability_shape_is_enforced(self):
        record = self._record()
        record["profile"]["metrics"]["thermalPressure"] = {"available": True}
        with self.assertRaisesRegex(contract.ContractError, "carries no value"):
            contract.validate_result(record)


if __name__ == "__main__":
    unittest.main()
