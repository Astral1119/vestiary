#!/usr/bin/env python3
"""Tests for the step 5 baseline harness — sub-sampling, the mid-block probe,
and the field list that carries a figure through to the summary.

The harness is only ever exercised for real by a run that needs a quiesced
machine and hours of wall clock, so the parts that decide whether a block is
trustworthy are covered here instead. Every case below is one the 2026-07-31
run either hit or would have hit.
"""

import hashlib
import importlib.util
import os
import pathlib
import shutil
import statistics
import tempfile
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


class ReduceDvfmStatesTest(unittest.TestCase):
    """The clock-state histogram, which says whether two launches drawing
    different power are doing different work or the same work at a different
    clock. It is reduced separately because it is a list, and `reduce_figures`
    would take a mean of one."""

    @staticmethod
    def sample(*pairs):
        return {
            "gpuDvfmStates": available(
                [{"freqMhz": freq, "usedRatio": ratio} for freq, ratio in pairs]
            )
        }

    def test_residency_is_averaged_per_state_over_the_sub_windows(self):
        reduced = harness.reduce_dvfm_states(
            [self.sample((338, 0.4), (1500, 0.6)),
             self.sample((338, 0.2), (1500, 0.8))]
        )
        self.assertEqual([s["freqMhz"] for s in reduced], [338, 1500])
        self.assertAlmostEqual(reduced[0]["usedRatio"], 0.3)
        self.assertAlmostEqual(reduced[1]["usedRatio"], 0.7)

    def test_a_state_absent_from_one_window_counts_as_zero_there(self):
        """Unlike a missing power field, an absent state means the clock was
        never entered in that window. Averaging over only the windows that
        listed it would report a state as busier than it was."""
        reduced = harness.reduce_dvfm_states(
            [self.sample((338, 0.5), (1500, 0.5)), self.sample((338, 1.0))]
        )
        self.assertAlmostEqual(reduced[1]["usedRatio"], 0.25)

    def test_states_are_ordered_by_frequency(self):
        reduced = harness.reduce_dvfm_states([self.sample((1500, 0.6), (338, 0.4))])
        self.assertEqual([s["freqMhz"] for s in reduced], [338, 1500])

    def test_no_histogram_in_any_window_yields_nothing(self):
        """An older macOS that stops emitting `dvfm_states` has to read as
        absent, not as an empty histogram that summarizes to zero residency."""
        self.assertIsNone(harness.reduce_dvfm_states([{}, {}]))
        self.assertIsNone(
            harness.reduce_dvfm_states([{"gpuDvfmStates": {"available": False}}])
        )


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


def snapshot(subject=(), strays=(), displays=None, drawing="AC Power"):
    return {
        "subjectHelpers": list(subject),
        "strayHelpers": list(strays),
        "displays": displays if displays is not None else {"count": 1},
        "powerSource": {"drawingFrom": drawing},
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


# --- the restart transient ------------------------------------------------


class RestartSubjectTest(unittest.TestCase):
    def setUp(self):
        self.sequence = []
        self.killed = []
        self.commands = []

        def fake_helpers():
            return self.sequence.pop(0) if self.sequence else []

        def fake_kill(pid, sig):
            self.killed.append(pid)

        def fake_run(command, **kwargs):
            self.commands.append(command)

        for module, name, replacement in (
            (harness, "helper_processes", fake_helpers),
            (harness.os, "kill", fake_kill),
            (harness.subprocess, "run", fake_run),
            (harness.time, "sleep", lambda seconds: None),
        ):
            self.addCleanup(setattr, module, name, getattr(module, name))
            setattr(module, name, replacement)

    @staticmethod
    def helpers(*pids):
        return [{"pid": pid, "command": "fresco-scene"} for pid in pids]

    def test_it_claims_the_new_pid_once_two_polls_agree(self):
        self.sequence = [
            self.helpers(),          # gone
            self.helpers(9100),      # back, but seen once
            self.helpers(9100),      # stable
        ]
        event = harness.restart_subject({22836}, 1, "", 60)
        self.assertEqual(event["previousPids"], [22836])
        self.assertEqual(event["pids"], [9100])
        self.assertEqual(self.killed, [22836])

    def test_it_does_not_claim_a_pid_that_is_about_to_exit(self):
        """A single sighting mid-teardown is not the new subject."""
        self.sequence = [
            self.helpers(9100),      # transient, seen once
            self.helpers(),          # it exited
            self.helpers(9200),
            self.helpers(9200),
        ]
        event = harness.restart_subject({22836}, 1, "", 60)
        self.assertEqual(event["pids"], [9200])

    def test_the_old_pid_surviving_is_not_a_restart(self):
        """The count matches and the process never died, so nothing restarted."""
        self.sequence = [self.helpers(22836), self.helpers(22836)]
        with self.assertRaises(harness.SubjectLost):
            harness.restart_subject({22836}, 1, "", 0.05)

    def test_a_subject_that_never_returns_ends_the_run(self):
        self.sequence = [self.helpers(), self.helpers()]
        with self.assertRaises(harness.SubjectLost) as raised:
            harness.restart_subject({22836}, 1, "", 0.05)
        self.assertIn("did not come back", str(raised.exception))

    def test_a_restart_command_replaces_the_signal(self):
        self.sequence = [self.helpers(9100), self.helpers(9100)]
        harness.restart_subject({22836}, 1, "fresco set 3326873240", 60)
        self.assertEqual(self.commands, ["fresco set 3326873240"])
        self.assertEqual(self.killed, [])

    def test_a_pid_that_is_already_gone_is_not_an_error(self):
        def raising_kill(pid, sig):
            raise ProcessLookupError

        harness.os.kill = raising_kill
        self.sequence = [self.helpers(9100), self.helpers(9100)]
        event = harness.restart_subject({22836}, 1, "", 60)
        self.assertEqual(event["pids"], [9100])


def transient_block(since, value):
    return {
        "valid": True,
        "blocksSinceRestart": since,
        "figures": {"cpuPowerMilliwatts": value},
    }


class RestartTransientTest(unittest.TestCase):
    def test_it_reports_the_excess_over_a_settled_block(self):
        blocks = [
            transient_block(0, 110.0),
            transient_block(1, 100.0),
            transient_block(2, 100.0),
            transient_block(0, 110.0),
            transient_block(1, 100.0),
            transient_block(2, 100.0),
        ]
        entry = harness.restart_transient_verdict(blocks)["cpuPowerMilliwatts"]
        self.assertAlmostEqual(entry["excessPercentOfSettled"], 10.0)
        self.assertAlmostEqual(entry["settledMean"], 100.0)

    def test_blocks_before_the_first_restart_are_in_neither_group(self):
        """Their subject had been up for an unknown time, so pooling them with
        settled blocks mixes two regimes."""
        blocks = [
            transient_block(None, 500.0),
            transient_block(None, 500.0),
            transient_block(0, 110.0),
            transient_block(0, 110.0),
            transient_block(1, 100.0),
            transient_block(2, 100.0),
        ]
        verdict = harness.restart_transient_verdict(blocks)
        self.assertEqual(verdict["firstBlockAfterRestart"], 2)
        self.assertEqual(verdict["settledBlocks"], 2)
        self.assertAlmostEqual(
            verdict["cpuPowerMilliwatts"]["settledMean"], 100.0
        )

    def test_one_cycle_is_not_enough_to_compare(self):
        blocks = [transient_block(0, 110.0), transient_block(1, 100.0)]
        verdict = harness.restart_transient_verdict(blocks)
        self.assertNotIn("cpuPowerMilliwatts", verdict)
        self.assertIn("two blocks in each group", verdict["note"])


class PowerSourceTest(unittest.TestCase):
    """Recording the source was all the harness did with it. An unattended run
    that loses AC kept producing blocks that validated."""

    def test_the_opening_source_holding_is_fine(self):
        harness.assert_preconditions(
            snapshot(drawing="AC Power"), None, (), "AC Power"
        )

    def test_losing_ac_mid_run_invalidates_the_block(self):
        with self.assertRaises(harness.ProtocolViolation) as raised:
            harness.assert_preconditions(
                snapshot(drawing="Battery Power"), None, (), "AC Power"
            )
        self.assertIn("power source changed mid-run", str(raised.exception))

    def test_a_run_that_opened_on_battery_is_not_forced_onto_ac(self):
        """Which source is correct is the run's choice; the check is that it
        does not change underneath it."""
        harness.assert_preconditions(
            snapshot(drawing="Battery Power"), None, (), "Battery Power"
        )
        with self.assertRaises(harness.ProtocolViolation):
            harness.assert_preconditions(
                snapshot(drawing="AC Power"), None, (), "Battery Power"
            )

    def test_no_reference_leaves_the_source_unchecked(self):
        harness.assert_preconditions(snapshot(drawing="Battery Power"), None)


# --- backend alternation --------------------------------------------------


class ParseBackendBinariesTest(unittest.TestCase):
    def setUp(self):
        self.directory = pathlib.Path(
            tempfile.mkdtemp(prefix="backend-binaries-")
        )
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)

    def executable(self, name):
        path = self.directory / name
        path.write_bytes(b"#!/bin/sh\n")
        path.chmod(0o755)
        return path

    def test_it_maps_labels_to_paths(self):
        native = self.executable("native")
        angle = self.executable("angle")
        mapping = harness.parse_backend_binaries(
            [f"native={native}", f"angle={angle}"]
        )
        self.assertEqual(mapping, {"native": native, "angle": angle})

    def test_a_missing_separator_is_rejected(self):
        with self.assertRaises(ValueError):
            harness.parse_backend_binaries(["native"])

    def test_a_repeated_label_is_rejected(self):
        """Silently keeping the last one would run a backend the command line
        does not read as naming."""
        native = self.executable("native")
        with self.assertRaises(ValueError) as raised:
            harness.parse_backend_binaries(
                [f"native={native}", f"native={native}"]
            )
        self.assertIn("twice", str(raised.exception))

    def test_a_path_that_is_not_there_is_rejected_before_the_run(self):
        with self.assertRaises(ValueError) as raised:
            harness.parse_backend_binaries(
                [f"angle={self.directory / 'absent'}"]
            )
        self.assertIn("not a file", str(raised.exception))

    def test_a_file_that_cannot_run_is_rejected(self):
        path = self.directory / "unreadable"
        path.write_bytes(b"")
        path.chmod(0o644)
        with self.assertRaises(ValueError) as raised:
            harness.parse_backend_binaries([f"angle={path}"])
        self.assertIn("not executable", str(raised.exception))


class BackendCycleTest(unittest.TestCase):
    def test_the_cycle_wraps(self):
        cycle = ["native", "native", "angle", "angle"]
        got = [harness.backend_for_restart(cycle, n) for n in range(8)]
        self.assertEqual(got, cycle + cycle)

    def test_runs_of_two_put_each_backend_on_both_launch_parities(self):
        """The property the cycle exists for. Launches alternate between two
        GPU clock states, so pairing restart index parity against backend is
        what says whether the comparison is confounded."""
        cycle = ["native", "native", "angle", "angle"]
        parities = {}
        for restart in range(8):
            label = harness.backend_for_restart(cycle, restart)
            parities.setdefault(label, set()).add(restart % 2)
        self.assertEqual(parities["native"], {0, 1})
        self.assertEqual(parities["angle"], {0, 1})

    def test_alternating_every_restart_is_the_confounded_shape(self):
        """Recorded as a test so the failure mode stays legible: this is what
        the 7-8% clock split would be reported as a backend delta."""
        cycle = ["native", "angle"]
        parities = {}
        for restart in range(8):
            label = harness.backend_for_restart(cycle, restart)
            parities.setdefault(label, set()).add(restart % 2)
        self.assertEqual(parities["native"], {0})
        self.assertEqual(parities["angle"], {1})


class InstallBackendTest(unittest.TestCase):
    def setUp(self):
        self.directory = pathlib.Path(
            tempfile.mkdtemp(prefix="install-backend-")
        )
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        self.source = self.directory / "angle-build"
        self.source.write_bytes(b"angle image")
        self.source.chmod(0o755)
        self.helper = self.directory / "runtime" / "bin" / "fresco-scene"

    def test_it_installs_the_image_and_reports_its_digest(self):
        event = harness.install_backend(
            "angle", {"angle": self.source}, self.helper
        )
        self.assertEqual(self.helper.read_bytes(), b"angle image")
        self.assertEqual(event["backend"], "angle")
        self.assertEqual(
            event["sha256"], hashlib.sha256(b"angle image").hexdigest()
        )
        self.assertEqual(event["bytes"], len(b"angle image"))

    def test_it_replaces_an_existing_image(self):
        self.helper.parent.mkdir(parents=True)
        self.helper.write_bytes(b"native image")
        harness.install_backend("angle", {"angle": self.source}, self.helper)
        self.assertEqual(self.helper.read_bytes(), b"angle image")

    def test_it_leaves_no_partial_image_behind(self):
        """The helper is copied to a staging name and moved into place, so a
        relaunch mid-swap never reads half a binary."""
        harness.install_backend("angle", {"angle": self.source}, self.helper)
        staged = self.helper.with_name(self.helper.name + ".swapping")
        self.assertFalse(staged.exists())

    def test_the_installed_image_stays_executable(self):
        harness.install_backend("angle", {"angle": self.source}, self.helper)
        self.assertTrue(os.access(self.helper, os.X_OK))


def backend_block(label, cpu, frequency):
    return {
        "valid": True,
        "backend": label,
        "figures": {
            "cpuPowerMilliwatts": cpu,
            "gpuFrequencyMhz": frequency,
        },
    }


class SummarizeByBackendTest(unittest.TestCase):
    def test_it_groups_figures_by_backend(self):
        blocks = [
            backend_block("native", 100.0, 400),
            backend_block("native", 102.0, 700),
            backend_block("angle", 110.0, 400),
            backend_block("angle", 112.0, 700),
        ]
        summary = harness.summarize_by_backend(blocks)
        self.assertEqual(summary["byBackend"]["native"]["blocks"], 2)
        self.assertAlmostEqual(
            summary["byBackend"]["native"]["cpuPowerMilliwatts"]["mean"], 101.0
        )
        self.assertAlmostEqual(
            summary["byBackend"]["angle"]["cpuPowerMilliwatts"]["mean"], 111.0
        )

    def test_both_backends_on_both_clock_states_is_balanced(self):
        blocks = [
            backend_block("native", 100.0, 400),
            backend_block("native", 102.0, 700),
            backend_block("angle", 110.0, 400),
            backend_block("angle", 112.0, 700),
        ]
        coverage = harness.summarize_by_backend(blocks)["parityCoverage"]
        self.assertEqual(coverage["sharedGpuFrequencyMhz"], [400, 700])
        self.assertTrue(coverage["balanced"])

    def test_one_backend_seeing_a_state_the_other_did_not_is_not_balanced(self):
        """The confounded run. Two means sitting side by side would read as a
        backend delta and be the clock."""
        blocks = [
            backend_block("native", 100.0, 400),
            backend_block("native", 101.0, 400),
            backend_block("angle", 110.0, 700),
            backend_block("angle", 111.0, 700),
        ]
        coverage = harness.summarize_by_backend(blocks)["parityCoverage"]
        self.assertEqual(coverage["sharedGpuFrequencyMhz"], [])
        self.assertFalse(coverage["balanced"])

    def test_blocks_without_a_backend_are_left_out(self):
        blocks = [
            backend_block("native", 100.0, 400),
            {"valid": True, "figures": {"cpuPowerMilliwatts": 999.0}},
        ]
        summary = harness.summarize_by_backend(blocks)
        self.assertEqual(list(summary["byBackend"]), ["native"])


if __name__ == "__main__":
    unittest.main()
