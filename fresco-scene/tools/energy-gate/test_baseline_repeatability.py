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
        self.stray = []
        self.busy = []
        for name, replacement in (
            ("stray_helper_processes", lambda: list(self.stray)),
            ("busy_processes", lambda threshold: list(self.busy)),
            ("load_average", lambda: {"1m": 0.1}),
        ):
            self.addCleanup(setattr, harness, name, getattr(harness, name))
            setattr(harness, name, replacement)

    def run_probe(self, during=None):
        probe = harness.MidBlockProbe(5.0, 0.01)
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
            self.stray = [{"pid": 4242, "command": "fresco-scene"}]
            time.sleep(0.05)
            self.stray = []

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
