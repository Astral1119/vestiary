#!/usr/bin/env python3
"""Tests for the step 5 baseline harness — sub-sampling, the mid-block probe,
and the field list that carries a figure through to the summary.

The harness is only ever exercised for real by a run that needs a quiesced
machine and hours of wall clock, so the parts that decide whether a block is
trustworthy are covered here instead. Every case below is one the 2026-07-31
run either hit or would have hit.
"""

import importlib.util
import pathlib
import statistics
import threading
import time
import unittest


def load_harness():
    """Load the harness by path; its filename has hyphens and cannot be
    imported by name."""
    path = pathlib.Path(__file__).resolve().parent / "baseline-repeatability.py"
    spec = importlib.util.spec_from_file_location("baseline_repeatability", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


harness = load_harness()


def available(value):
    return {"available": True, "value": value}


# --- sub-sampling ---------------------------------------------------------


class SamplePowerTest(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.reading = {"available": True, "sampleCount": 0, "samples": []}
        original = harness.profiling_sampler.sample_powermetrics

        def fake(samples, interval_ms, target_pids=None):
            self.calls.append({"samples": samples, "interval_ms": interval_ms})
            return self.reading

        harness.profiling_sampler.sample_powermetrics = fake
        self.addCleanup(
            setattr, harness.profiling_sampler, "sample_powermetrics", original
        )

    def test_window_is_split_into_equal_sub_windows(self):
        self.reading["samples"] = [{}] * 6
        harness.sample_power(120, 6)
        self.assertEqual(
            self.calls[0], {"samples": 6, "interval_ms": 20_000}
        )

    def test_single_sub_sample_asks_for_the_whole_window(self):
        """k=1 must reproduce the call the step 5 run made, so the baseline it
        measured stays comparable."""
        self.reading["samples"] = [{}]
        harness.sample_power(120, 1)
        self.assertEqual(
            self.calls[0], {"samples": 1, "interval_ms": 120_000}
        )

    def test_short_return_invalidates_the_block(self):
        """Fewer sub-windows than requested means powermetrics did not measure
        the window that was asked for."""
        self.reading["samples"] = [{}] * 4
        with self.assertRaises(harness.ProtocolViolation) as raised:
            harness.sample_power(120, 6)
        self.assertIn("4 sub-samples of 6", str(raised.exception))

    def test_unavailable_sampler_invalidates_the_block(self):
        self.reading = {"available": False, "reason": "powermetrics not found"}
        with self.assertRaises(harness.ProtocolViolation) as raised:
            harness.sample_power(120, 6)
        self.assertIn("powermetrics not found", str(raised.exception))


class ReduceFiguresTest(unittest.TestCase):
    def test_block_figure_is_the_mean_of_its_sub_windows(self):
        reduced = harness.reduce_figures(
            [
                {"cpuPowerMilliwatts": 30.0},
                {"cpuPowerMilliwatts": 40.0},
                {"cpuPowerMilliwatts": 50.0},
            ]
        )
        self.assertAlmostEqual(reduced["cpuPowerMilliwatts"], 40.0)

    def test_a_field_missing_from_one_sub_window_averages_the_rest(self):
        """`parse_power` omits a field it could not read rather than zeroing it,
        so counting the absence as a low value would understate the mean."""
        reduced = harness.reduce_figures(
            [
                {"cpuPowerMilliwatts": 30.0, "gpuPowerMilliwatts": 1.0},
                {"cpuPowerMilliwatts": 50.0},
            ]
        )
        self.assertAlmostEqual(reduced["cpuPowerMilliwatts"], 40.0)
        self.assertAlmostEqual(reduced["gpuPowerMilliwatts"], 1.0)

    def test_no_sub_windows_yields_no_figures(self):
        self.assertEqual(harness.reduce_figures([]), {})


# --- the field list -------------------------------------------------------


class PowerFieldsTest(unittest.TestCase):
    def test_parsed_fields_are_the_summarized_fields(self):
        """These were two lists that disagreed. The summary asked for
        `aneMilliwatts`, which the sampler never emits, and omitted
        `gpuActiveResidency`, which every block records."""
        sample = {name: available(1.0) for name in harness.POWER_FIELDS}
        self.assertEqual(
            set(harness.parse_power(sample)), set(harness.POWER_FIELDS)
        )

    def test_gpu_active_residency_survives_to_a_figure(self):
        figures = harness.parse_power({"gpuActiveResidency": available(0.13)})
        self.assertEqual(figures, {"gpuActiveResidency": 0.13})

    def test_an_unavailable_field_is_omitted_rather_than_zeroed(self):
        figures = harness.parse_power(
            {
                "cpuPowerMilliwatts": available(37.6),
                "gpuPowerMilliwatts": {"available": False},
            }
        )
        self.assertEqual(figures, {"cpuPowerMilliwatts": 37.6})


# --- the mid-block probe --------------------------------------------------


class MidBlockProbeTest(unittest.TestCase):
    def setUp(self):
        self.helpers = []
        self.busy = []
        for name, replacement in (
            ("helper_processes", lambda: list(self.helpers)),
            ("busy_processes", lambda threshold: list(self.busy)),
            ("load_average", lambda: {"1m": 0.1}),
        ):
            self.addCleanup(setattr, harness, name, getattr(harness, name))
            setattr(harness, name, replacement)

    def run_probe(self, during=None, subject_pids=()):
        probe = harness.MidBlockProbe(5.0, 0.01, subject_pids)
        probe.start()
        if during is not None:
            during()
        # Long enough for several intervals at 10ms, short enough to keep the
        # suite fast.
        time.sleep(0.15)
        probe.stop()
        return probe

    def test_it_observes_while_the_window_is_open(self):
        probe = self.run_probe()
        self.assertGreater(probe.digest()["probeCount"], 1)

    def test_it_catches_a_helper_that_never_touches_a_boundary(self):
        """The 2026-07-31 outlier class: load that starts and ends inside the
        window, so both boundary snapshots read clean."""

        def during():
            self.helpers = [{"pid": 4242, "command": "fresco-scene"}]
            time.sleep(0.05)
            self.helpers = []

        digest = self.run_probe(during).digest()
        self.assertEqual(
            digest["strayHelpers"], [{"pid": 4242, "command": "fresco-scene"}]
        )

    def test_it_keeps_the_peak_per_process_not_every_reading(self):
        self.busy = [{"cpuPercent": 12.0, "pid": 7, "command": "mobileassetd"}]

        def during():
            self.busy = [
                {"cpuPercent": 88.0, "pid": 7, "command": "mobileassetd"}
            ]
            time.sleep(0.05)
            self.busy = [
                {"cpuPercent": 3.0, "pid": 7, "command": "mobileassetd"}
            ]

        digest = self.run_probe(during).digest()
        peaks = digest["peakBusyProcesses"]
        self.assertEqual(len(peaks), 1)
        self.assertEqual(peaks[0]["cpuPercent"], 88.0)

    def test_stopping_ends_the_thread(self):
        """A probe left running would sample into the next block's window."""
        before = threading.active_count()
        probe = harness.MidBlockProbe(5.0, 0.01)
        probe.start()
        time.sleep(0.05)
        probe.stop()
        self.assertEqual(threading.active_count(), before)

    def test_a_probe_that_saw_nothing_reports_a_clean_digest(self):
        digest = self.run_probe().digest()
        self.assertEqual(digest["strayHelpers"], [])
        self.assertEqual(digest["peakBusyProcesses"], [])

    def test_the_subject_is_not_reported_as_a_stray(self):
        """The loaded run's whole point. Without this the subject invalidates
        every block it renders."""
        self.helpers = [{"pid": 22836, "command": "fresco-scene"}]
        digest = self.run_probe(subject_pids={22836}).digest()
        self.assertEqual(digest["strayHelpers"], [])
        self.assertEqual(digest["observationsMissingSubject"], 0)

    def test_a_subject_that_dies_inside_the_window_is_counted(self):
        """Both boundary snapshots read correct if it respawns before the
        window closes, and the block is then measuring a restart rather than a
        steady workload."""
        self.helpers = [{"pid": 22836, "command": "fresco-scene"}]

        def during():
            self.helpers = []
            time.sleep(0.05)
            self.helpers = [{"pid": 22836, "command": "fresco-scene"}]

        digest = self.run_probe(during, subject_pids={22836}).digest()
        self.assertGreater(digest["observationsMissingSubject"], 0)

    def test_a_second_helper_beside_the_subject_is_a_stray(self):
        """A leaked helper is caught by pid, not by count — the ANGLE pass was
        invalidated by five of them."""
        self.helpers = [
            {"pid": 22836, "command": "fresco-scene"},
            {"pid": 9001, "command": "fresco-scene"},
        ]
        digest = self.run_probe(subject_pids={22836}).digest()
        self.assertEqual(
            digest["strayHelpers"], [{"pid": 9001, "command": "fresco-scene"}]
        )


# --- ownership ------------------------------------------------------------


def snapshot(subject=(), strays=(), displays=None):
    return {
        "subjectHelpers": list(subject),
        "strayHelpers": list(strays),
        "displays": displays if displays is not None else {"count": 1},
    }


class ClassifyHelpersTest(unittest.TestCase):
    def test_an_empty_subject_set_makes_every_helper_a_stray(self):
        """The idle step 5 rule, reproduced rather than special-cased."""
        found = [{"pid": 1, "command": "fresco-scene"}]
        subject, strays = harness.classify_helpers(found, frozenset())
        self.assertEqual(subject, [])
        self.assertEqual(strays, found)

    def test_it_splits_on_pid(self):
        found = [
            {"pid": 1, "command": "fresco-scene"},
            {"pid": 2, "command": "fresco-scene"},
        ]
        subject, strays = harness.classify_helpers(found, {2})
        self.assertEqual([e["pid"] for e in subject], [2])
        self.assertEqual([e["pid"] for e in strays], [1])


class PreconditionTest(unittest.TestCase):
    def test_the_subject_does_not_invalidate_its_own_block(self):
        harness.assert_preconditions(
            snapshot(subject=[{"pid": 7, "command": "fresco-scene"}]),
            {"count": 1},
            {7},
        )

    def test_a_stray_still_invalidates_a_loaded_block(self):
        with self.assertRaises(harness.ProtocolViolation) as raised:
            harness.assert_preconditions(
                snapshot(
                    subject=[{"pid": 7, "command": "fresco-scene"}],
                    strays=[{"pid": 8, "command": "fresco-scene"}],
                ),
                {"count": 1},
                {7},
            )
        self.assertIn("fresco-scene(8)", str(raised.exception))

    def test_a_dead_subject_invalidates_rather_than_reading_as_idle(self):
        """A block sampled after the workload died is a clean idle baseline,
        which is the one failure that looks like a good measurement."""
        with self.assertRaises(harness.ProtocolViolation) as raised:
            harness.assert_preconditions(snapshot(), {"count": 1}, {7})
        self.assertIn("expected [7], found []", str(raised.exception))

    def test_a_restarted_subject_is_not_the_one_the_run_claimed(self):
        """Same count, different process. Its first block carries the restart
        transient the calibration measures separately."""
        with self.assertRaises(harness.ProtocolViolation):
            harness.assert_preconditions(
                snapshot(subject=[{"pid": 9, "command": "fresco-scene"}]),
                {"count": 1},
                {7},
            )

    def test_an_idle_run_still_refuses_any_helper(self):
        with self.assertRaises(harness.ProtocolViolation) as raised:
            harness.assert_preconditions(
                snapshot(strays=[{"pid": 7, "command": "fresco-scene"}]),
                {"count": 1},
            )
        self.assertIn("fresco-scene(7)", str(raised.exception))


# --- window length --------------------------------------------------------


def block(values):
    """A valid block whose sub-windows carried `values` on CPU power."""
    return {
        "valid": True,
        "subFigures": [{"cpuPowerMilliwatts": v} for v in values],
        "figures": {"cpuPowerMilliwatts": statistics.fmean(values)},
    }


class WindowLengthTest(unittest.TestCase):
    def test_it_separates_sampling_noise_from_block_to_block_movement(self):
        """Blocks that differ far more than their sub-windows do: the spread is
        the machine, and the window is already long enough."""
        blocks = [
            block([10.0, 10.1, 9.9, 10.0]),
            block([40.0, 40.1, 39.9, 40.0]),
            block([70.0, 70.1, 69.9, 70.0]),
        ]
        verdict = harness.window_length_verdict(blocks, 120, 4)
        entry = verdict["cpuPowerMilliwatts"]
        self.assertLess(entry["samplingShareOfBetweenVariancePercent"], 1.0)
        self.assertLess(entry["sufficientWindowSeconds"], 120)

    def test_it_reports_no_drift_when_sub_windows_explain_the_spread(self):
        """Identical blocks with noisy sub-windows. Nothing says the blocks
        differ, so there is no drift term to size a window against."""
        blocks = [
            block([10.0, 90.0, 10.0, 90.0]),
            block([90.0, 10.0, 90.0, 10.0]),
        ]
        entry = harness.window_length_verdict(blocks, 120, 4)[
            "cpuPowerMilliwatts"
        ]
        self.assertIsNone(entry["sufficientWindowSeconds"])
        self.assertIsNone(entry["driftCoefficientOfVariationPercent"])
        self.assertIn("no block-to-block movement", entry["note"])

    def test_it_records_the_sub_window_length(self):
        verdict = harness.window_length_verdict([block([1.0, 2.0])], 120, 2)
        self.assertEqual(verdict["subWindowSeconds"], 60)
        self.assertEqual(verdict["windowSeconds"], 120)

    def test_too_few_blocks_yield_no_field_entry(self):
        verdict = harness.window_length_verdict([block([1.0, 2.0])], 120, 2)
        self.assertNotIn("cpuPowerMilliwatts", verdict)


if __name__ == "__main__":
    unittest.main()
