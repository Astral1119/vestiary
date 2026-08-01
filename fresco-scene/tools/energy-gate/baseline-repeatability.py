#!/usr/bin/env python3

"""Step 5 of the backend profiling protocol: measure baseline repeatability.

PROPOSAL.md:562 puts this before any candidate comparison, and nothing in the
tree has run it. The question is not which backend costs less. It is whether
this machine can produce a repeatable idle baseline at all, because a
candidate delta means nothing until the measurement noise floor is known.

Step 5 itself takes no workload and loads no backend. It samples an idle,
quiesced machine in repeated bracketed blocks and reports the spread. If the
spread is wide relative to any plausible backend delta, that is the answer to
whether the comparison is affordable here, and it is worth having before a
night is spent on steps 6 and 7.

The loaded calibration run uses the same harness with a subject. Step 5
measured an idle machine, and Q10 compares two backends under load, so the
figure that sizes Q10 is loaded CoV rather than idle CoV. `--subject-helpers`
says how many renderer processes the workload legitimately runs; those are the
subject and everything else is still a stray. With the default of 0 the run is
step 5 exactly as it was measured, because an empty subject set makes every
helper a stray.

`--restart-every` makes the run restart its own subject on a fixed cadence and
stamp each block with how many blocks have passed since. Q10 pays a helper
restart on every backend swap, so the transient decides how much of each
alternation has to be discarded, and blocked alternation was proposed partly
to pay it eight times less often. The restart lands after the settle and
immediately before the window, so the transient falls inside what is measured
rather than being settled away.

powermetrics needs root, but the script does not. A NOPASSWD sudoers rule
covering /usr/bin/powermetrics is enough and is what this machine has, so the
script probes the sampler at startup rather than demanding euid 0 — the euid
check used to refuse runs that would have worked. Either way the credential
must be non-interactive: a long unattended run cannot answer a password prompt,
and re-authenticating per block would itself perturb the measurement.

    ./baseline-repeatability.py --blocks 12 --sample-seconds 120 \
        --store ../../../.fresco-evidence/energy-baseline-v1

Protocol obligations this implements, from PROPOSAL.md:566-574 and
BRIEF.md:111-115:
  - fix and record power source, low-power mode, display topology, thermal state
  - verify process ownership before every block; the earlier ANGLE pass was
    invalidated by five leaked full-resolution helper processes
  - retain raw repeated measurements rather than summaries alone
  - invalidate a block when thermal, display, background, or ownership state
    violates the protocol, rather than silently averaging it in
"""

import argparse
import datetime
import json
import os
import pathlib
import re
import signal
import statistics
import subprocess
import sys
import threading
import time

sys.path.insert(
    0, str(pathlib.Path(__file__).resolve().parent.parent / "common-harness")
)
import profiling_sampler  # noqa: E402 - path is set immediately above

HELPER_PROCESS_NAMES = ("fresco-scene", "Fresco")
SAMPLE_INTERVAL_MILLISECONDS = 1000

# The figures carried from a sample all the way through to the summary. This was
# two lists that disagreed: the summary asked for `aneMilliwatts`, which
# `profiling_sampler` does not emit and which therefore never appeared, and it
# omitted `gpuActiveResidency`, which every block records. The 2026-07-31 run
# collected 150 blocks of GPU residency and summarized none of it. One list means
# a field added to the sampler cannot be reduced by one site and dropped by the
# other.
POWER_FIELDS = (
    "cpuPowerMilliwatts",
    "gpuPowerMilliwatts",
    "packagePowerMilliwatts",
    "gpuActiveResidency",
)


class ProtocolViolation(Exception):
    """A precondition failed. The block is invalidated rather than recorded."""


class SubjectLost(Exception):
    """The subject workload did not come back. The run ends rather than a block.

    A restart that never completes leaves every remaining block failing the
    ownership check, so continuing spends the rest of the run's wall clock
    producing invalid blocks.
    """


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def run_text(command):
    completed = subprocess.run(
        command, capture_output=True, text=True, check=False
    )
    return completed.stdout


def power_source():
    """AC or battery, and whether a battery is present and charged.

    The protocol fixes power source per trial. On a laptop the choice also
    changes thermal and scheduling behaviour, so it is recorded rather than
    assumed.
    """
    text = run_text(["pmset", "-g", "ps"])
    drawing = "unknown"
    match = re.search(r"Now drawing from '([^']+)'", text)
    if match:
        drawing = match.group(1)
    return {"drawingFrom": drawing, "raw": text.strip()}


def power_settings(active_source):
    """Settings that move power draw during an unattended run.

    `powermode` is the low-power/high-power selector the protocol asks to be
    fixed, and pmset reports it per power source rather than globally, so the
    active source decides which block applies.

    displaysleep and powernap are recorded because they are the two that
    silently invalidate an overnight baseline. An internal display switching
    off partway through a run is a step change in draw, and any block spanning
    the transition measures the display rather than the machine. Power Nap
    wakes background work during exactly the idle windows being sampled.
    """
    text = run_text(["pmset", "-g", "custom"])
    sections = {}
    current = None
    for line in text.splitlines():
        if line.endswith("Power:"):
            current = line[:-1].strip()
            sections[current] = {}
            continue
        if current is None:
            continue
        parts = line.strip().rsplit(None, 1)
        if len(parts) == 2 and parts[1].lstrip("-").isdigit():
            sections[current][parts[0].strip()] = int(parts[1])

    heading = "AC Power" if "AC" in active_source else "Battery Power"
    active = sections.get(heading, {})
    warnings = []
    if active.get("displaysleep", 0) != 0:
        warnings.append(
            f"displaysleep is {active['displaysleep']} minutes; the display will "
            "switch off mid-run and any block spanning that transition is "
            "measuring the display. Either set it to 0 for the run or make the "
            "initial settle longer than it so every block sees the same state."
        )
    if active.get("powernap", 0) != 0:
        warnings.append(
            "powernap is enabled; background work can wake during the sampled "
            "idle windows and will show up as baseline spread."
        )
    if active.get("sleep", 0) != 0:
        warnings.append(
            f"sleep is {active['sleep']} minutes; the run will not survive it."
        )
    return {
        "activeSourceHeading": heading,
        "powermode": active.get("powermode"),
        "displaysleepMinutes": active.get("displaysleep"),
        "powernap": active.get("powernap"),
        "sleepMinutes": active.get("sleep"),
        "standby": active.get("standby"),
        "warnings": warnings,
        "allSections": sections,
    }


def thermal_state():
    return {"raw": run_text(["pmset", "-g", "therm"]).strip()}


def display_topology():
    """Resolution, refresh and count. A display change invalidates a block."""
    text = run_text(
        ["system_profiler", "SPDisplaysDataType", "-json", "-detailLevel", "mini"]
    )
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        return {"error": "display topology unavailable", "raw": text[:2000]}
    displays = []
    for card in parsed.get("SPDisplaysDataType", []):
        for display in card.get("spdisplays_ndrvs", []):
            displays.append(
                {
                    "name": display.get("_name"),
                    "resolution": display.get("_spdisplays_resolution")
                    or display.get("spdisplays_resolution"),
                    "online": display.get("spdisplays_online"),
                }
            )
    return {"count": len(displays), "displays": displays}


def load_average():
    try:
        one, five, fifteen = os.getloadavg()
    except OSError:
        return None
    return {"1m": one, "5m": five, "15m": fifteen}


def helper_processes():
    """Every renderer or daemon process on the machine, subject or not.

    BRIEF.md:111-113 records that five leaked full-resolution helpers
    invalidated the earlier ANGLE pass. Enumerating them is cheap enough to run
    before every block; deciding which of them belong to the run is
    `classify_helpers`.
    """
    text = run_text(["ps", "-Ao", "pid=,comm="])
    found = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        pid, _, command = stripped.partition(" ")
        basename = os.path.basename(command.strip())
        if basename in HELPER_PROCESS_NAMES:
            found.append({"pid": int(pid), "command": command.strip()})
    return found


def classify_helpers(found, subject_pids):
    """Split the helpers into the ones the run owns and the ones it does not.

    An idle run passes an empty subject set, which makes every helper a stray —
    the step 5 rule, reproduced rather than special-cased. A loaded run names
    its subject by pid, so a leaked or restarted helper is still caught: it has
    a pid the run never claimed.
    """
    subject, strays = [], []
    for entry in found:
        (subject if entry["pid"] in subject_pids else strays).append(entry)
    return subject, strays


def busy_processes(threshold_percent):
    """Top CPU consumers, so a noisy baseline can be attributed after the fact.

    Recorded rather than enforced. Deciding that some background process
    disqualifies a block is a judgement for whoever reads the evidence; this
    only makes the judgement possible.
    """
    text = run_text(["ps", "-Ao", "pcpu=,pid=,comm="])
    busy = []
    for line in text.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3:
            continue
        try:
            percent = float(parts[0])
        except ValueError:
            continue
        if percent >= threshold_percent:
            busy.append(
                {"cpuPercent": percent, "pid": int(parts[1]), "command": parts[2]}
            )
    busy.sort(key=lambda entry: entry["cpuPercent"], reverse=True)
    return busy[:20]


def environment_snapshot(busy_threshold, subject_pids=()):
    source = power_source()
    subject, strays = classify_helpers(helper_processes(), subject_pids)
    return {
        "at": utc_now(),
        "powerSource": source,
        "powerSettings": power_settings(source["drawingFrom"]),
        "thermal": thermal_state(),
        "displays": display_topology(),
        "loadAverage": load_average(),
        "subjectHelpers": subject,
        "strayHelpers": strays,
        "busyProcesses": busy_processes(busy_threshold),
    }


class MidBlockProbe:
    """Watches the machine during the sampling window, not only at its edges.

    The 2026-07-31 baseline run recorded five outlier blocks — 06:30 to 06:42
    plus one straggler at 07:28 — that lifted CPU power from a 37.6 mW median to
    as much as 83.3 mW and took the run's reported CPU CoV from 4.65% to 13.63%.
    All five were stamped valid with empty `strayHelpers`, because the load
    started and ended inside the 120-second window and touched neither boundary
    snapshot. Two of the five have empty snapshots on both sides, so their cause
    is inferred from timing rather than measured.

    Sampling from a thread while powermetrics holds the window is what makes
    that class of contamination visible. The probe runs on the same schedule
    regardless of what it finds; deciding whether an observation disqualifies a
    block stays with whoever reads the evidence.
    """

    def __init__(self, busy_threshold, interval_seconds, subject_pids=()):
        self._busy_threshold = busy_threshold
        self._interval = interval_seconds
        self._subject_pids = frozenset(subject_pids)
        self._stop = threading.Event()
        self._thread = None
        self.observations = []

    def _loop(self):
        # `wait` returns True once stop is set, so the loop ends promptly at the
        # end of the block instead of sleeping out its last full interval. The
        # first observation lands one interval in, since t=0 is already covered
        # by the `before` snapshot.
        while not self._stop.wait(self._interval):
            subject, strays = classify_helpers(
                helper_processes(), self._subject_pids
            )
            self.observations.append(
                {
                    "at": utc_now(),
                    "loadAverage": load_average(),
                    "subjectHelpers": subject,
                    "strayHelpers": strays,
                    "busyProcesses": busy_processes(self._busy_threshold),
                }
            )

    def start(self):
        self._stop.clear()
        self.observations = []
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=30)
            self._thread = None

    def digest(self):
        """What goes in the record: the peak per process, not every reading.

        The full series goes to the raw file. The record is rewritten after
        every block and an unabridged series across 150 blocks would bloat it
        without being read, so the record keeps the shape a reader needs to
        decide whether the block is trustworthy.
        """
        strays = {}
        peaks = {}
        missing_subject = 0
        for observation in self.observations:
            if {
                entry["pid"] for entry in observation["subjectHelpers"]
            } != self._subject_pids:
                missing_subject += 1
            for entry in observation["strayHelpers"]:
                strays[entry["pid"]] = entry
            for entry in observation["busyProcesses"]:
                command = entry["command"]
                if entry["cpuPercent"] > peaks.get(command, {}).get(
                    "cpuPercent", -1.0
                ):
                    peaks[command] = entry
        ranked = sorted(
            peaks.values(), key=lambda entry: entry["cpuPercent"], reverse=True
        )
        return {
            "probeCount": len(self.observations),
            "probeIntervalSeconds": self._interval,
            "strayHelpers": sorted(strays.values(), key=lambda e: e["pid"]),
            # A subject that dies and respawns inside the window leaves both
            # boundary snapshots reading correct, exactly as the 2026-07-31
            # outlier load did. The block after it is measuring a restart
            # transient rather than a steady workload.
            "observationsMissingSubject": missing_subject,
            "peakBusyProcesses": ranked[:20],
        }


def assert_preconditions(snapshot, reference_displays, subject_pids=()):
    """Raise if the block cannot be trusted. Invalidation beats averaging.

    Two ownership failures, not one. A stray helper adds load the run did not
    ask for; a missing subject helper removes the load the run exists to
    measure, and a block sampled after the workload died reads as a clean idle
    baseline rather than as a failure.
    """
    if snapshot["strayHelpers"]:
        raise ProtocolViolation(
            "renderer or daemon processes are running: "
            + ", ".join(
                f"{entry['command']}({entry['pid']})"
                for entry in snapshot["strayHelpers"]
            )
        )
    present = {entry["pid"] for entry in snapshot.get("subjectHelpers", [])}
    if present != frozenset(subject_pids):
        raise ProtocolViolation(
            "the subject workload is not the one the run claimed: expected "
            f"{sorted(subject_pids)}, found {sorted(present)}"
        )
    if reference_displays is not None:
        if snapshot["displays"] != reference_displays:
            raise ProtocolViolation("display topology changed mid-run")


def restart_subject(
    subject_pids, expected_count, command, timeout_seconds, poll_seconds=0.5
):
    """Restart the subject workload and re-claim it, or give up on the run.

    The default action is SIGTERM to each claimed pid, because Fresco's
    supervisor relaunches a helper that exits unexpectedly
    (`SceneSupervisor.swift:680`) and killing the process is the closest thing
    to what a backend swap does. Its restart budget is three within a
    sixty-second window and older entries are filtered out, so a cadence of one
    restart per block never accumulates against it. `--restart-command` is for a
    subject that needs a different mechanism.

    A note on what this does and does not reproduce: a Q10 backend swap also
    replaces the installed binary, so its relaunch pays page-in cost for a
    different image. What is measured here is the process-lifecycle share of
    the transient, which is the share blocked alternation was proposed to
    amortize.

    The new subject is claimed only once two consecutive polls agree, the count
    matches, and none of the previous pids survive. Claiming mid-teardown would
    hand the run a pid that is about to exit.
    """
    previous = frozenset(subject_pids)
    started = time.monotonic()
    if command:
        subprocess.run(command, shell=True, capture_output=True, text=True)
    else:
        for pid in sorted(previous):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                # Already gone. The wait below is what decides the outcome.
                pass

    seen = None
    while time.monotonic() - started < timeout_seconds:
        time.sleep(poll_seconds)
        current = frozenset(entry["pid"] for entry in helper_processes())
        if (
            len(current) == expected_count
            and not (current & previous)
            and current == seen
        ):
            return {
                "at": utc_now(),
                "previousPids": sorted(previous),
                "pids": sorted(current),
                "waitSeconds": time.monotonic() - started,
                "command": command or "SIGTERM to the claimed pids",
            }
        seen = current

    raise SubjectLost(
        f"the subject did not come back within {timeout_seconds}s of a restart: "
        f"expected {expected_count} helpers with pids outside "
        f"{sorted(previous)}, last saw {sorted(seen or ())}"
    )


def sample_power(seconds, subsamples):
    """One powermetrics window, split into `subsamples` equal sub-windows.

    This used to shell out to powermetrics itself and pull the figures back
    out of the human-readable summary with regexes. Those regexes never ran:
    powermetrics needs root and the script had not been run under sudo, so a
    field name that had moved would have surfaced only after a night of
    sampling. `profiling_sampler` asks for the plist form instead and parses it
    through candidate key paths, and its parsers are covered by eighteen tests
    against fixtures taken on this machine.

    The window used to be one sample, which made whether 120s is longer than it
    needs to be unanswerable from the record: each raw file held one
    already-averaged figure and there was no within-block series to subsample.
    Asking for k samples at `seconds / k` each costs the same wall clock and
    makes the sufficient window length readable after the fact. Measured on
    2026-07-31: `samples=3, interval_ms=1000` returns three distinct parsed
    sub-samples, so the sampler does return all k rather than collapsing them.

    A short return is a protocol violation rather than a shorter block. The
    caller asked for a window of a fixed length and powermetrics delivering
    fewer sub-windows means it did not measure that window.
    """
    interval = max(
        1, seconds * SAMPLE_INTERVAL_MILLISECONDS // subsamples
    )
    reading = profiling_sampler.sample_powermetrics(
        samples=subsamples, interval_ms=interval
    )
    if not reading.get("available"):
        raise ProtocolViolation(
            f"powermetrics unavailable: {reading.get('reason', 'unknown')}"
        )
    samples = reading.get("samples") or []
    if not samples:
        raise ProtocolViolation("powermetrics returned no parsable sample")
    if len(samples) != subsamples:
        raise ProtocolViolation(
            f"powermetrics returned {len(samples)} sub-samples of "
            f"{subsamples} requested"
        )
    return samples


def reduce_figures(sub_figures):
    """The block's headline figure, as the unweighted mean of its sub-samples.

    The sub-windows are equal in length, so an unweighted mean over them is the
    same quantity the single whole-window sample used to report. That keeps
    blocks measured before and after sub-sampling comparable, which matters
    because the step 5 baseline this is sized from was measured the old way.

    A field is averaged over the sub-samples that carried it. `parse_power`
    omits a field it could not read rather than defaulting it to zero, so
    counting only the present ones avoids folding an absence in as a low value.
    """
    collected = {}
    for figures in sub_figures:
        for name, value in figures.items():
            collected.setdefault(name, []).append(value)
    return {name: statistics.fmean(values) for name, values in collected.items()}


def parse_power(sample):
    """The headline figures, unwrapped from the sampler's availability form.

    A field the sampler could not supply is left out rather than defaulted to
    zero, because a zero would silently understate a mean.
    """
    figures = {}
    for name in POWER_FIELDS:
        entry = sample.get(name)
        if isinstance(entry, dict) and entry.get("available"):
            figures[name] = entry["value"]
    return figures


def summarize(values):
    """Spread of the per-block figures. This is the deliverable of step 5.

    The coefficient of variation is the number that answers the question:
    a backend delta smaller than the baseline's own spread is not measurable
    on this machine no matter how many blocks are run.
    """
    if len(values) < 2:
        return {"count": len(values), "note": "two blocks minimum for a spread"}
    mean = statistics.fmean(values)
    deviation = statistics.stdev(values)
    return {
        "count": len(values),
        "mean": mean,
        "stdev": deviation,
        "min": min(values),
        "max": max(values),
        "rangeAsPercentOfMean": (
            (max(values) - min(values)) / mean * 100.0 if mean else None
        ),
        "coefficientOfVariationPercent": (
            deviation / mean * 100.0 if mean else None
        ),
    }


def window_length_verdict(valid_blocks, sample_seconds, subsamples):
    """Whether the sampling window is longer than it needs to be.

    This is the question sub-sampling exists to answer, and it was unanswerable
    from the 2026-07-31 run: each raw file held one already-averaged figure, so
    there was no within-block series to work from.

    A block's figure is the mean of k sub-windows, so the spread between blocks
    carries two things — real block-to-block movement, and the sampling noise
    left in each block's own mean. Averaging k sub-windows divides the second by
    k, which separates them:

        between = drift + within / k

    When the sampling term is a small share of `between`, the window is already
    long enough that lengthening it buys nothing, and the reported spread is
    measuring the machine rather than the sampler. `sufficientWindowSeconds` is
    the window at which the sampling term falls to a tenth of the drift term,
    taking sampling variance as inversely proportional to averaging time.

    That proportionality assumes the sub-windows are independent, and on this
    machine they are not: the 2026-07-31 run measured lag-1 autocorrelation of
    +0.295 on CPU power between blocks fifteen minutes apart. Correlated
    sub-windows average more slowly than the formula, so treat
    `sufficientWindowSeconds` as a floor rather than a recommendation.
    """
    sub_window = sample_seconds / subsamples
    verdict = {
        "windowSeconds": sample_seconds,
        "subWindowSeconds": sub_window,
        "subSamples": subsamples,
    }
    for field in POWER_FIELDS:
        series = [
            [f[field] for f in block["subFigures"] if field in f]
            for block in valid_blocks
            if len(block.get("subFigures") or []) > 1
        ]
        series = [values for values in series if len(values) > 1]
        means = [
            block["figures"][field]
            for block in valid_blocks
            if field in block.get("figures", {})
        ]
        if len(series) < 2 or len(means) < 2:
            continue
        mean = statistics.fmean(means)
        if not mean:
            continue
        within = statistics.fmean(
            [statistics.variance(values) for values in series]
        )
        between = statistics.variance(means)
        sampling = within / subsamples
        drift = between - sampling
        entry = {
            "withinBlockCoefficientOfVariationPercent": (
                within ** 0.5 / mean * 100.0
            ),
            "betweenBlockCoefficientOfVariationPercent": (
                between ** 0.5 / mean * 100.0
            ),
            "samplingShareOfBetweenVariancePercent": (
                sampling / between * 100.0 if between else None
            ),
        }
        if drift > 0:
            entry["driftCoefficientOfVariationPercent"] = (
                drift ** 0.5 / mean * 100.0
            )
            entry["sufficientWindowSeconds"] = within * sub_window / (0.1 * drift)
        else:
            # The sub-window noise accounts for the whole between-block spread.
            # Nothing here says the blocks differ, so there is no drift term to
            # size a window against, and a longer window is what would tell them
            # apart if they do.
            entry["driftCoefficientOfVariationPercent"] = None
            entry["sufficientWindowSeconds"] = None
            entry["note"] = (
                "within-block noise explains the full between-block spread; "
                "no block-to-block movement is resolvable at this window"
            )
        verdict[field] = entry
    return verdict


def restart_transient_verdict(valid_blocks):
    """How much the first block after a restart differs from a settled one.

    Q10 pays this on every backend swap. If the excess is small against the
    settled spread then a swap costs nothing and per-block alternation is
    affordable; if it is large, each alternation has to discard its first block
    or run in longer runs, which is what blocked alternation buys.

    Only blocks from the restart-cycled part of the run are compared. Blocks
    before the first restart carry a null `blocksSinceRestart` — the helper had
    been up for an unknown time — and pooling them with settled blocks would
    mix two regimes to make the settled group look larger than it is.

    This is a comparison of two means with their counts, not a test. Thirty
    blocks at a cadence of five put six in the fresh group, which is enough to
    see a transient that matters and not enough to rule out a small one.
    """
    fresh, settled = [], []
    for block in valid_blocks:
        since = block.get("blocksSinceRestart")
        if since is None:
            continue
        (fresh if since == 0 else settled).append(block)

    verdict = {"firstBlockAfterRestart": len(fresh), "settledBlocks": len(settled)}
    if len(fresh) < 2 or len(settled) < 2:
        verdict["note"] = (
            "two blocks in each group minimum; run more restart cycles"
        )
        return verdict

    for field in POWER_FIELDS:
        fresh_values = [
            b["figures"][field] for b in fresh if field in b.get("figures", {})
        ]
        settled_values = [
            b["figures"][field] for b in settled if field in b.get("figures", {})
        ]
        if len(fresh_values) < 2 or len(settled_values) < 2:
            continue
        fresh_mean = statistics.fmean(fresh_values)
        settled_mean = statistics.fmean(settled_values)
        if not settled_mean:
            continue
        settled_deviation = statistics.stdev(settled_values)
        verdict[field] = {
            "firstBlockAfterRestartMean": fresh_mean,
            "settledMean": settled_mean,
            "excessPercentOfSettled": (
                (fresh_mean - settled_mean) / settled_mean * 100.0
            ),
            "settledCoefficientOfVariationPercent": (
                settled_deviation / settled_mean * 100.0
            ),
        }
    return verdict


def write_record(output_path, record):
    """Write the record to disk. Called after every block, not once at the end.

    An unattended run that dies at hour six otherwise leaves the raw samples on
    disk with no record of which blocks were valid or what the machine was
    doing during them, and those per-block snapshots are what decide whether a
    block is trustworthy. The raw sample alone cannot answer that.

    The write goes to a temporary file and is renamed over the target. Writing
    150 times makes a crash during a write a real possibility, and a truncated
    record is worse than a stale one because it reads as valid JSON right up
    until it does not.
    """
    temporary = output_path.with_suffix(".partial")
    temporary.write_text(
        json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.replace(temporary, output_path)


def main():
    parser = argparse.ArgumentParser(
        description="Measure idle baseline repeatability (protocol step 5)."
    )
    parser.add_argument("--blocks", type=int, default=12)
    parser.add_argument("--sample-seconds", type=int, default=120)
    parser.add_argument(
        "--settle-seconds", type=int, default=60,
        help="Quiet time before each block, so the previous block's heat and "
             "scheduler state do not carry into the next one.",
    )
    parser.add_argument(
        "--initial-settle-seconds", type=int, default=0,
        help="Extra quiet time before the first block only. Set this longer "
             "than displaysleep so the display is already off when block 0 "
             "starts and every block sees the same display state.",
    )
    parser.add_argument(
        "--sub-samples", type=int, default=6,
        help="Split each block's window into this many equal sub-windows. "
             "Costs no extra wall clock and is what makes the sufficient "
             "window length answerable from the record afterwards. 1 restores "
             "the single whole-window sample the step 5 run used.",
    )
    parser.add_argument(
        "--probe-seconds", type=int, default=15,
        help="How often to sample load and busy processes during the window. "
             "The boundary snapshots miss any load that starts and ends inside "
             "the block, which is how the 2026-07-31 run stamped its five "
             "outlier blocks valid. 0 disables the probe.",
    )
    parser.add_argument("--busy-threshold-percent", type=float, default=5.0)
    parser.add_argument(
        "--subject-helpers", type=int, default=0,
        help="How many renderer processes the subject workload legitimately "
             "runs; 1 for a single live scene. Those become the subject and "
             "every other helper is still a stray. 0 is the idle step 5 run, "
             "where any helper at all disqualifies the machine.",
    )
    parser.add_argument(
        "--subject-note", default="",
        help="What the subject is — scene, backend, resolution. A loaded "
             "record is unreadable later without it, and nothing else in the "
             "record says which workload was rendering.",
    )
    parser.add_argument(
        "--restart-every", type=int, default=0,
        help="Restart the subject before every Nth block, so the transient a "
             "Q10 backend swap pays is measurable. 0 never restarts.",
    )
    parser.add_argument(
        "--restart-command", default="",
        help="Shell command that restarts the subject. The default sends "
             "SIGTERM to the claimed pids and waits for the supervisor to "
             "relaunch, which is what a backend swap does to the helper.",
    )
    parser.add_argument(
        "--restart-timeout-seconds", type=int, default=60,
        help="How long to wait for the subject to come back before ending the "
             "run. A subject that never returns fails every remaining block.",
    )
    parser.add_argument("--store", required=True, type=pathlib.Path)
    arguments = parser.parse_args()

    if arguments.subject_helpers < 0:
        sys.exit("--subject-helpers cannot be negative")
    if arguments.restart_every < 0:
        sys.exit("--restart-every cannot be negative")
    if arguments.restart_every and not arguments.subject_helpers:
        sys.exit(
            "--restart-every needs a subject; --subject-helpers is 0, so there "
            "is nothing for the run to restart"
        )

    if arguments.sub_samples < 1:
        sys.exit("--sub-samples must be at least 1")
    if arguments.sub_samples > arguments.sample_seconds:
        sys.exit(
            f"--sub-samples {arguments.sub_samples} exceeds --sample-seconds "
            f"{arguments.sample_seconds}; a sub-window cannot be under a second"
        )

    # Probe rather than require euid 0. powermetrics needs root, but a NOPASSWD
    # sudoers rule covering it is enough and is what this machine has, so
    # demanding the whole script run as root refused a run that would have
    # worked. The probe is one short sample and answers the question the
    # euid check was standing in for.
    probe = profiling_sampler.sample_powermetrics(samples=1, interval_ms=200)
    if not probe.get("available"):
        sys.exit(
            f"powermetrics is unavailable: {probe.get('reason', 'unknown')}\n"
            "It needs root. Either add a NOPASSWD sudoers rule for it, or "
            "re-run the whole script under sudo:\n"
            "  sudo ./baseline-repeatability.py --store <dir>\n"
            "Running it once rather than per block is deliberate — an "
            "unattended overnight run cannot answer a password prompt."
        )

    store = arguments.store
    store.mkdir(parents=True, exist_ok=True)
    raw_directory = store / "raw"
    raw_directory.mkdir(exist_ok=True)
    output = store / "baseline-repeatability-v1.json"

    # The subject is claimed once, before the first snapshot, and by pid. A
    # count alone would let a helper die and be replaced between blocks without
    # anything noticing, and the replacement's first block carries the restart
    # transient the calibration is meant to measure separately.
    found_helpers = helper_processes()
    subject_pids = frozenset(entry["pid"] for entry in found_helpers)
    opening = environment_snapshot(
        arguments.busy_threshold_percent, subject_pids
    )
    reference_displays = opening["displays"]

    record = {
        "schemaVersion": 1,
        "purpose": (
            "backend-profiling-loaded-calibration"
            if arguments.subject_helpers
            else "backend-profiling-step-5-baseline-repeatability"
        ),
        "startedAt": utc_now(),
        "parameters": {
            "blocks": arguments.blocks,
            "sampleSeconds": arguments.sample_seconds,
            "settleSeconds": arguments.settle_seconds,
            "subSamples": arguments.sub_samples,
            "probeSeconds": arguments.probe_seconds,
            "subjectHelpers": arguments.subject_helpers,
            "subjectNote": arguments.subject_note,
            "restartEvery": arguments.restart_every,
            "restartCommand": arguments.restart_command,
        },
        "subjectPids": sorted(subject_pids),
        "restarts": [],
        "openingEnvironment": opening,
        "blocks": [],
    }

    if len(found_helpers) != arguments.subject_helpers:
        listed = ", ".join(
            f"{entry['command']}({entry['pid']})" for entry in found_helpers
        ) or "none"
        if len(found_helpers) > arguments.subject_helpers:
            # The ANGLE pass was invalidated by five leaked full-resolution
            # helpers, which is this branch with the count set to one.
            reason = (
                f"{len(found_helpers)} renderer or daemon processes were "
                f"running before the first block and the run claimed "
                f"{arguments.subject_helpers}; quiesce Fresco and verify "
                "ownership before measuring"
            )
        else:
            reason = (
                f"the subject workload is not running: {arguments.subject_helpers} "
                f"helpers were claimed and {len(found_helpers)} are up; a run "
                "that starts without its workload measures an idle machine and "
                "reports it as loaded"
            )
        record["abandonedAt"] = utc_now()
        record["abandonReason"] = reason
        write_record(output, record)
        sys.exit(f"fail: {reason} — {listed}")

    for warning in opening["powerSettings"]["warnings"]:
        print(f"warning: {warning}", flush=True)

    if arguments.initial_settle_seconds:
        print(
            f"initial settle: {arguments.initial_settle_seconds}s", flush=True
        )
        time.sleep(arguments.initial_settle_seconds)

    # None until the first restart. A block before it had a subject that had
    # been up for an unknown time, which is neither fresh nor part of the
    # restart-cycled regime the transient is read from.
    blocks_since_restart = None
    abandoned = False

    for index in range(arguments.blocks):
        time.sleep(arguments.settle_seconds)

        # After the settle and before the window, so the transient is inside
        # what the block measures rather than settled away ahead of it.
        restart = None
        if arguments.restart_every and index % arguments.restart_every == 0:
            try:
                restart = restart_subject(
                    subject_pids,
                    arguments.subject_helpers,
                    arguments.restart_command,
                    arguments.restart_timeout_seconds,
                )
            except SubjectLost as lost:
                record["abandonedAt"] = utc_now()
                record["abandonReason"] = str(lost)
                write_record(output, record)
                print(f"fail: {lost}", flush=True)
                abandoned = True
                break
            subject_pids = frozenset(restart["pids"])
            record["restarts"].append(dict(restart, beforeBlock=index))
            blocks_since_restart = 0
            print(
                f"restart before block {index}: {restart['previousPids']} -> "
                f"{restart['pids']} in {restart['waitSeconds']:.1f}s",
                flush=True,
            )
        elif blocks_since_restart is not None:
            blocks_since_restart += 1

        before = environment_snapshot(
            arguments.busy_threshold_percent, subject_pids
        )
        block = {
            "index": index,
            "blocksSinceRestart": blocks_since_restart,
            "before": before,
        }
        probe_watcher = (
            MidBlockProbe(
                arguments.busy_threshold_percent,
                arguments.probe_seconds,
                subject_pids,
            )
            if arguments.probe_seconds > 0
            else None
        )
        try:
            assert_preconditions(before, reference_displays, subject_pids)
            if probe_watcher is not None:
                probe_watcher.start()
            try:
                samples = sample_power(
                    arguments.sample_seconds, arguments.sub_samples
                )
            finally:
                # Stopped in a finally so a violation inside the window does not
                # leave the thread sampling into the next block.
                if probe_watcher is not None:
                    probe_watcher.stop()
            # The parsed sub-samples are written before they are reduced, so a
            # figure the parser missed costs a re-read rather than the night.
            raw_path = raw_directory / f"block-{index:03d}.powermetrics.json"
            raw_path.write_text(
                json.dumps(samples, indent=2, default=str), encoding="utf-8"
            )
            block["rawPath"] = raw_path.name
            sub_figures = [parse_power(sample) for sample in samples]
            block["figures"] = reduce_figures(sub_figures)
            if len(sub_figures) > 1:
                block["subFigures"] = sub_figures
                # Within-block spread is the quantity that says whether the
                # window is longer than it needs to be. It only means anything
                # against the between-block spread, so it is recorded per block
                # and compared in the summary rather than judged here.
                block["withinBlock"] = {
                    field: summarize(
                        [f[field] for f in sub_figures if field in f]
                    )
                    for field in POWER_FIELDS
                    if any(field in f for f in sub_figures)
                }
            if probe_watcher is not None:
                digest = probe_watcher.digest()
                probe_path = raw_directory / f"block-{index:03d}.probe.json"
                probe_path.write_text(
                    json.dumps(
                        probe_watcher.observations, indent=2, default=str
                    ),
                    encoding="utf-8",
                )
                digest["rawPath"] = probe_path.name
                block["during"] = digest
                # A helper that runs entirely inside the window contaminates the
                # block exactly as much as one caught at a boundary, so it is
                # treated the same. Busy processes stay recorded rather than
                # enforced, which is also how the boundary snapshots treat them.
                if digest["strayHelpers"]:
                    raise ProtocolViolation(
                        "renderer or daemon processes ran during the window: "
                        + ", ".join(
                            f"{entry['command']}({entry['pid']})"
                            for entry in digest["strayHelpers"]
                        )
                    )
                if digest["observationsMissingSubject"]:
                    raise ProtocolViolation(
                        "the subject workload was absent for "
                        f"{digest['observationsMissingSubject']} of "
                        f"{digest['probeCount']} observations inside the window"
                    )
            after = environment_snapshot(
                arguments.busy_threshold_percent, subject_pids
            )
            block["after"] = after
            assert_preconditions(after, reference_displays, subject_pids)
            block["valid"] = True
        except ProtocolViolation as violation:
            block["valid"] = False
            block["invalidationReason"] = str(violation)
        record["blocks"].append(block)
        write_record(output, record)
        print(
            f"block {index}: "
            + ("ok " if block["valid"] else "INVALID ")
            + json.dumps(block.get("figures", {})),
            flush=True,
        )

    valid = [b for b in record["blocks"] if b["valid"]]
    record["summary"] = {
        "validBlocks": len(valid),
        "invalidBlocks": len(record["blocks"]) - len(valid),
        # A run that ended early still summarizes what it collected. The flag
        # is what stops those blocks being read as the run that was asked for.
        "abandoned": abandoned,
    }
    for field in POWER_FIELDS:
        values = [
            b["figures"][field] for b in valid if field in b.get("figures", {})
        ]
        if values:
            record["summary"][field] = summarize(values)
    if arguments.sub_samples > 1:
        record["summary"]["windowLength"] = window_length_verdict(
            valid, arguments.sample_seconds, arguments.sub_samples
        )
    if arguments.restart_every:
        record["summary"]["restartTransient"] = restart_transient_verdict(valid)
    record["completedAt"] = utc_now()
    record["closingEnvironment"] = environment_snapshot(
        arguments.busy_threshold_percent, subject_pids
    )

    write_record(output, record)
    print(f"\nwrote {output}")
    print(json.dumps(record["summary"], indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
