"""Host, display, and power sampling for the profiling evidence profile.

Produces the `profile`, `host`, and `display` record sections defined in
docs/FRESCO-GRAPHICS-ARCHITECTURE-PROPOSAL.md (evidence contract, purpose
`profiling`). The serialized profiling protocol that drives this sampler lives
in run_profiling.py; this module only reads the machine.

Sources, by privilege:
  - powermetrics (root)  -> CPU/GPU power, GPU active residency, per-task
                            wakeups and Energy Impact, thermal pressure.
  - pmset (unprivileged) -> power source, low-power mode, thermal warning.
  - vm_stat, ps, sysctl  -> memory, process manifest, host identity.

Every parser is a pure function over captured bytes/text so it can be tested
against fixtures without the live machine. Metrics that a source does not
supply are reported EXPLICIT-UNAVAILABLE, never zero (PROPOSAL: "Unavailable
metrics required by the selected purpose are explicit rather than recorded as
zero").
"""

from __future__ import annotations

import plistlib
import re
import shutil
import subprocess

# Sentinel for a metric a source did not supply. A profiling verdict treats a
# required metric carrying this value as a validity failure, distinct from a
# real zero measurement.
UNAVAILABLE = {"available": False}


def _available(value):
    return {"available": True, "value": value}


# --- pure parsers ---------------------------------------------------------


def parse_powermetrics_plist(data: bytes, target_pids=None) -> dict:
    """Extract the power/thermal/task fields from one `powermetrics -f plist`
    sample. The plist schema drifts across macOS releases, so every field is
    looked up through candidate paths and reported unavailable when absent.
    `target_pids` restricts the task rollup to the candidate process tree."""
    try:
        root = plistlib.loads(data)
    except Exception as exc:  # noqa: BLE001 - surface as an explicit failure
        return {"parseError": str(exc), "cpuPower": UNAVAILABLE,
                "gpuPower": UNAVAILABLE, "gpuActiveResidency": UNAVAILABLE,
                "thermalPressure": UNAVAILABLE, "tasks": UNAVAILABLE}

    processor = root.get("processor", {}) if isinstance(root, dict) else {}
    gpu = root.get("gpu", {}) if isinstance(root, dict) else {}

    def first(container, keys):
        for key in keys:
            if isinstance(container, dict) and key in container:
                return container[key]
        return None

    # Power is milliwatts on Apple Silicon. Keys vary: package/combined at the
    # processor node, gpu under either the processor or a dedicated gpu node.
    cpu_power = first(processor, ["cpu_power", "cpu_power_mW"])
    gpu_power = first(processor, ["gpu_power", "gpu_power_mW"])
    if gpu_power is None:
        gpu_power = first(gpu, ["gpu_power", "gpu_power_mW"])
    package_power = first(processor, ["package_power", "combined_power"])

    # GPU active residency = 1 - idle_ratio, when the gpu node reports it.
    idle_ratio = first(gpu, ["idle_ratio"])
    gpu_active = None if idle_ratio is None else max(0.0, 1.0 - float(idle_ratio))

    thermal = root.get("thermal_pressure") if isinstance(root, dict) else None

    tasks = root.get("tasks") if isinstance(root, dict) else None
    task_roll = _rollup_tasks(tasks, target_pids) if isinstance(tasks, list) \
        else UNAVAILABLE

    return {
        "cpuPowerMilliwatts": _available(cpu_power) if cpu_power is not None else UNAVAILABLE,
        "gpuPowerMilliwatts": _available(gpu_power) if gpu_power is not None else UNAVAILABLE,
        "packagePowerMilliwatts": _available(package_power) if package_power is not None else UNAVAILABLE,
        "gpuActiveResidency": _available(gpu_active) if gpu_active is not None else UNAVAILABLE,
        "thermalPressure": _available(thermal) if thermal is not None else UNAVAILABLE,
        "tasks": task_roll,
        "elapsedNs": _available(root.get("elapsed_ns")) if isinstance(root, dict) and "elapsed_ns" in root else UNAVAILABLE,
    }


def _rollup_tasks(tasks: list, target_pids) -> dict:
    """Roll up per-task cost over the candidate process tree. Energy Impact is
    absent on some macOS builds (the key is present but null); report whether
    any real value was seen rather than summing nulls to a fake zero. cputime
    is the reliable CPU-cost signal there."""
    target = set(target_pids) if target_pids else None
    energy_impact = 0.0
    energy_seen = False
    wakeups = 0
    cputime_ns = 0
    cputime_ms_per_s = 0.0
    matched = 0
    for task in tasks:
        if not isinstance(task, dict):
            continue
        pid = task.get("pid")
        if target is not None and pid not in target:
            continue
        matched += 1
        ei = task.get("energy_impact")
        if isinstance(ei, (int, float)):
            energy_impact += float(ei)
            energy_seen = True
        for key in ("intr_wakeups", "idle_wakeups", "timer_wakeups"):
            val = task.get(key)
            if isinstance(val, (int, float)):
                wakeups += int(val)
        cns = task.get("cputime_ns")
        if isinstance(cns, (int, float)):
            cputime_ns += int(cns)
        cms = task.get("cputime_ms_per_s")
        if isinstance(cms, (int, float)):
            cputime_ms_per_s += float(cms)
    return {
        "available": True,
        "matchedProcesses": matched,
        "energyImpact": energy_impact,
        "energyAvailable": energy_seen,
        "wakeups": wakeups,
        "cputimeNs": cputime_ns,
        "cputimeMsPerSecond": cputime_ms_per_s,
        "scoped": target is not None,
    }


def parse_pmset_power(text: str) -> dict:
    """Power source and low-power mode. Feed the combined output of
    `pmset -g ps` (power source line) and `pmset -g` (the `powermode` /
    `lowpowermode` setting; the key name varies across releases)."""
    source = None
    match = re.search(r"drawing from '([^']+)'", text)
    if match:
        source = match.group(1)
    lpm = None
    match = re.search(r"(?:low)?powermode\s+(\d)", text)
    if match:
        lpm = match.group(1) == "1"
    return {
        "powerSource": _available(source) if source is not None else UNAVAILABLE,
        "lowPowerMode": _available(lpm) if lpm is not None else UNAVAILABLE,
    }


def parse_pmset_therm(text: str) -> dict:
    """Thermal/CPU-power constraint from `pmset -g therm`. A quiet system
    prints 'No thermal warning level has been recorded'."""
    warned = "No thermal warning level" not in text
    speed_limit = None
    match = re.search(r"CPU_Speed_Limit\s*=\s*(\d+)", text)
    if match:
        speed_limit = int(match.group(1))
    return {
        "thermalWarning": _available(warned),
        "cpuSpeedLimit": _available(speed_limit) if speed_limit is not None else UNAVAILABLE,
    }


def parse_vm_stat(text: str) -> dict:
    """Resident/free memory in bytes from `vm_stat`."""
    page = re.search(r"page size of (\d+) bytes", text)
    page_size = int(page.group(1)) if page else 4096
    counts = {}
    for name, label in (("free", "Pages free"),
                        ("active", "Pages active"),
                        ("inactive", "Pages inactive"),
                        ("wired", "Pages wired down"),
                        ("compressed", "Pages occupied by compressor")):
        match = re.search(re.escape(label) + r":\s+(\d+)", text)
        if match:
            counts[name] = int(match.group(1)) * page_size
    return {"pageSize": page_size, "bytes": counts}


def parse_ps_manifest(text: str, root_pids) -> dict:
    """Build the process tree rooted at the candidate pids from
    `ps -eo pid,ppid,rss,comm`. Returns the tree and any fresco/helper
    processes NOT descended from a declared root (an ownership violation)."""
    procs = {}
    for line in text.strip().splitlines()[1:]:
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pid, ppid, rss = int(parts[0]), int(parts[1]), int(parts[2])
        except ValueError:
            continue
        procs[pid] = {"pid": pid, "ppid": ppid, "rssKb": rss, "comm": parts[3]}

    roots = set(root_pids)
    tree = {}
    for pid, info in procs.items():
        cur, depth = pid, 0
        while cur in procs and depth < 64:
            if cur in roots:
                tree[pid] = info
                break
            cur = procs[cur]["ppid"]
            depth += 1

    strays = [info for pid, info in procs.items()
              if pid not in tree
              and re.search(r"fresco|scene", info["comm"], re.IGNORECASE)]
    return {
        "tree": sorted(tree.values(), key=lambda p: p["pid"]),
        "strayFrescoProcesses": sorted(strays, key=lambda p: p["pid"]),
    }


# --- live collection (side effects) ---------------------------------------


def _run(cmd, timeout=10):
    return subprocess.run(cmd, capture_output=True, text=True,
                          timeout=timeout, check=False)


def sysctl_host() -> dict:
    keys = ["hw.model", "machdep.cpu.brand_string", "hw.memsize", "hw.ncpu",
            "hw.perflevel0.logicalcpu", "hw.perflevel1.logicalcpu"]
    out = {}
    for key in keys:
        res = _run(["sysctl", "-n", key])
        out[key] = res.stdout.strip() if res.returncode == 0 else None
    return {
        "model": out.get("hw.model"),
        "cpuBrand": out.get("machdep.cpu.brand_string"),
        "memoryBytes": int(out["hw.memsize"]) if out.get("hw.memsize") else None,
        "logicalCpus": int(out["hw.ncpu"]) if out.get("hw.ncpu") else None,
        "performanceCpus": int(out["hw.perflevel0.logicalcpu"]) if out.get("hw.perflevel0.logicalcpu") else None,
        "efficiencyCpus": int(out["hw.perflevel1.logicalcpu"]) if out.get("hw.perflevel1.logicalcpu") else None,
    }


def collect_power_state() -> dict:
    source = _run(["pmset", "-g", "ps"])
    settings = _run(["pmset", "-g"])
    therm = _run(["pmset", "-g", "therm"])
    combined = "\n".join(r.stdout for r in (source, settings) if r.returncode == 0)
    state = parse_pmset_power(combined)
    if therm.returncode == 0:
        state.update(parse_pmset_therm(therm.stdout))
    return state


def collect_memory() -> dict:
    res = _run(["vm_stat"])
    return parse_vm_stat(res.stdout) if res.returncode == 0 else {"bytes": {}}


def collect_process_manifest(root_pids) -> dict:
    res = _run(["ps", "-eo", "pid,ppid,rss,comm"])
    if res.returncode != 0:
        return {"tree": [], "strayFrescoProcesses": []}
    return parse_ps_manifest(res.stdout, root_pids)


def sample_powermetrics(samples: int = 1, interval_ms: int = 200,
                        target_pids=None) -> dict:
    """Take `samples` powermetrics samples via sudo. Returns EXPLICIT-
    UNAVAILABLE with a reason when powermetrics is missing or sudo is not
    passwordless — the caller records that as an energy-metrics gap rather
    than a zero measurement, and marks the run invalid if energy is required."""
    if shutil.which("powermetrics") is None:
        return {"available": False, "reason": "powermetrics not found"}
    # Attempt powermetrics directly (a NOPASSWD sudoers rule may cover only it,
    # so probing `sudo -n true` would wrongly report sudo unavailable).
    cmd = ["sudo", "-n", "powermetrics", "-n", str(samples),
           "-i", str(interval_ms), "-f", "plist",
           "--samplers", "cpu_power,gpu_power,tasks"]
    res = _run(cmd, timeout=max(20, samples * interval_ms // 1000 + 12))
    if res.returncode != 0:
        reason = ("powermetrics needs passwordless sudo (add a sudoers rule)"
                  if "password" in (res.stderr or "").lower()
                  else f"powermetrics exit {res.returncode}")
        return {"available": False, "reason": reason}
    # -n N with plist emits N concatenated plists separated by a null byte.
    chunks = [c for c in res.stdout.encode("utf-8", "replace").split(b"\x00") if c.strip()]
    parsed = [parse_powermetrics_plist(chunk, target_pids) for chunk in chunks]
    return {"available": True, "sampleCount": len(parsed), "samples": parsed}
