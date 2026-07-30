#!/usr/bin/env python3
"""Root-only profiling runner (result version 3).

Runs a baseline-before -> candidate -> baseline-after bracket, sampling host
power, thermal, and memory around the candidate phase, and emits one validated
profiling record plus a human priority summary.

Two modes:
  --attach   (default) sample the live Fresco process tree. Opportunistic:
             real numbers on the actual running wallpaper, always marked
             validity:false because the machine is not under the controlled
             quiescence protocol. This is the "where is the cost" measurement.
  a controlled candidate (a launched workload, machine quiesced) is the path
  to a valid baseline; it reuses the same record shape with validity:true.

Energy, GPU, and wakeup metrics require powermetrics (sudo). Without a primed
sudo they are recorded explicit-unavailable and the run is invalid, which is
the intended dev-selftest shape. Nothing here profiles from a subagent — the
contract rejects that.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import statistics
import tempfile
import time

import contract
import profiling_sampler as sampler

BRACKET = ["baseline-before", "candidate", "baseline-after"]
REQUIRED = ["cpuPowerMilliwatts", "gpuPowerMilliwatts", "wakeups"]
DEFAULT_BINARY = pathlib.Path.home() / ".config/fresco/bin/fresco-scene"
MANIFEST = pathlib.Path(__file__).with_name("workloads") / "static-no-media" / "manifest-v1.json"


def _utc_now():
    # Wall clock is only a record annotation, not a measurement input.
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 16), b""):
            digest.update(block)
    return digest.hexdigest()


def collect_display():
    """Best-effort main-display geometry. Returns (display, resolved)."""
    import subprocess
    fallback = {
        "logicalWidth": 1512, "logicalHeight": 982,
        "pixelWidth": 3024, "pixelHeight": 1964,
        "scaleMilli": 2000, "maximumRefreshMilliHertz": 60000,
        "colorSpace": "unknown",
    }
    try:
        out = subprocess.run(
            ["system_profiler", "SPDisplaysDataType", "-json"],
            capture_output=True, text=True, timeout=20, check=False)
        data = json.loads(out.stdout)
        for gpu in data.get("SPDisplaysDataType", []):
            for disp in gpu.get("spdisplays_ndrvs", []):
                res = disp.get("_spdisplays_resolution") or disp.get("spdisplays_resolution", "")
                match = re.search(r"(\d+)\s*x\s*(\d+).*?([\d.]+)\s*Hz", res)
                if not match:
                    continue
                width, height = int(match.group(1)), int(match.group(2))
                refresh = int(round(float(match.group(3)) * 1000))
                pixels = disp.get("_spdisplays_pixels", "")
                pmatch = re.search(r"(\d+)\s*x\s*(\d+)", pixels)
                pw, ph = (int(pmatch.group(1)), int(pmatch.group(2))) if pmatch else (width, height)
                scale = max(1000, round(pw / width * 1000)) if width else 1000
                return ({
                    "logicalWidth": width, "logicalHeight": height,
                    "pixelWidth": pw, "pixelHeight": ph,
                    "scaleMilli": scale, "maximumRefreshMilliHertz": max(1, refresh),
                    "colorSpace": "unknown",
                }, True)
    except Exception:  # noqa: BLE001 - best effort, fall back
        pass
    return (fallback, False)


def find_fresco_tree():
    """Locate the live Fresco process tree. Returns (root_pids, all_pids)."""
    import subprocess
    res = subprocess.run(["ps", "-eo", "pid,ppid,rss,comm"],
                         capture_output=True, text=True, check=False)
    procs = {}
    for line in res.stdout.strip().splitlines()[1:]:
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        procs[pid] = {"ppid": ppid, "comm": parts[3]}
    fresco = {pid for pid, p in procs.items()
              if re.search(r"fresco", p["comm"], re.IGNORECASE)}
    roots = {pid for pid in fresco if procs[pid]["ppid"] not in fresco}
    return roots, fresco


def _aggregate_power(samples):
    """Returns (schema metrics, extras). Extras carry per-tree cputime, which
    is the CPU-cost signal where Energy Impact is unavailable."""
    cpu, gpu, residency, cputime_ms = [], [], [], []
    energy = 0.0
    energy_seen = False
    wakeups = 0
    cputime_ns = 0
    tasks_seen = False
    for sample in samples:
        for key, sink in (("cpuPowerMilliwatts", cpu),
                          ("gpuPowerMilliwatts", gpu),
                          ("gpuActiveResidency", residency)):
            field = sample.get(key, {})
            if field.get("available"):
                sink.append(field["value"])
        tasks = sample.get("tasks", {})
        if tasks.get("available"):
            tasks_seen = True
            wakeups += tasks.get("wakeups", 0)
            cputime_ns += tasks.get("cputimeNs", 0)
            cputime_ms.append(tasks.get("cputimeMsPerSecond", 0.0))
            if tasks.get("energyAvailable"):
                energy += tasks.get("energyImpact", 0.0)
                energy_seen = True

    def mean_metric(values):
        return {"available": True, "value": statistics.fmean(values)} if values else {"available": False}

    metrics = {
        "cpuPowerMilliwatts": mean_metric(cpu),
        "gpuPowerMilliwatts": mean_metric(gpu),
        "gpuActiveResidency": mean_metric(residency),
        "energyImpact": {"available": True, "value": energy} if energy_seen else {"available": False},
        "wakeups": {"available": True, "value": wakeups} if tasks_seen else {"available": False},
    }
    extras = {
        "cputimeMsPerSecond": statistics.fmean(cputime_ms) if cputime_ms else None,
        "wakeupsPerWindow": wakeups if tasks_seen else None,
    }
    return metrics, extras


def _sample_phase(samples, interval_ms, target_pids):
    power = sampler.sample_powermetrics(samples=samples, interval_ms=interval_ms,
                                        target_pids=target_pids)
    manifest = sampler.collect_process_manifest(root_pids=target_pids or {-1})
    rss_bytes = sum(p["rssKb"] * 1024 for p in manifest["tree"])
    return {
        "power": power,
        "targetRssBytes": rss_bytes,
        "strayFrescoProcesses": manifest["strayFrescoProcesses"],
    }


def run(args):
    binary = pathlib.Path(args.binary)
    binary_sha = _sha256_file(binary) if binary.exists() else contract.canonical_hash("absent-binary")
    manifest = contract.load_json(MANIFEST)
    host = sampler.sysctl_host()
    power_state = sampler.collect_power_state()
    display, display_resolved = collect_display()

    roots, fresco = find_fresco_tree()
    target = fresco if args.attach else set()

    started = _utc_now()
    phases = {}
    for phase in BRACKET:
        pids = target if phase == "candidate" else set()
        phases[phase] = _sample_phase(args.samples, args.interval_ms, pids)
        time.sleep(0)  # placeholder ordering point; real protocol settles here
    completed = _utc_now()

    candidate_power = phases["candidate"]["power"]
    thermal = power_state.get("thermalWarning", {})
    thermal_value = "Fair" if thermal.get("available") and thermal.get("value") else "Nominal"
    metrics = {"contextSwitches": {"available": False},
               "thermalPressure": {"available": True, "value": thermal_value},
               "memoryBytes": {"available": True, "value": phases["candidate"]["targetRssBytes"]}}
    extras = {}
    if candidate_power.get("available"):
        samples = candidate_power["samples"]
        if len(samples) > 1:
            samples = samples[1:]  # discard the first delta (warmup / since-start)
        aggregate, extras = _aggregate_power(samples)
        metrics.update(aggregate)
    for key in ("cpuPowerMilliwatts", "gpuPowerMilliwatts", "gpuActiveResidency",
                "energyImpact", "wakeups"):
        metrics.setdefault(key, {"available": False})

    strays = phases["candidate"]["strayFrescoProcesses"]
    ownership_clean = not strays and args.attach  # attach: the tree IS the target
    missing = [k for k in REQUIRED if not metrics[k]["available"]]

    reasons = []
    if args.attach:
        reasons.append("opportunistic-attach")
    if args.dev_selftest:
        reasons.append("dev-selftest")
    if missing:
        reasons.append("energy-metrics-unavailable")
    if not ownership_clean:
        reasons.append("ownership-violation")
    if not display_resolved:
        reasons.append("display-unresolved")
    valid = not reasons

    record = _assemble(args, manifest, host, display, power_state, metrics,
                       ownership_clean, strays, reasons, valid, binary_sha,
                       started, completed, candidate_power)
    return record, metrics, reasons, valid, power_state, extras


def _assemble(args, manifest, host, display, power_state, metrics,
              ownership_clean, strays, reasons, valid, binary_sha,
              started, completed, candidate_power):
    store = pathlib.Path(os.path.realpath(args.store))
    # Ingest sources must be physical, symlink-free paths too; stage them
    # inside the (already resolved) store rather than the /var-symlinked tmp.
    sources = store / "_ingest-src"
    sources.mkdir(parents=True, exist_ok=True)
    raw = {"powerState": power_state, "candidatePower": candidate_power,
           "strayCount": len(strays)}
    raw_path = sources / "powermetrics-raw.json"
    raw_path.write_text(json.dumps(raw, indent=2))
    powermetrics_artifact = contract.ingest_artifact(
        raw_path, store, "powermetrics-raw", "application/json")
    build_path = sources / "build-log.txt"
    build_path.write_text("attached to installed fresco-scene\n")
    build_artifact = contract.ingest_artifact(
        build_path, store, "build-log", "text/plain")

    source_sha = contract.canonical_hash({"runner": "run_profiling", "mode": "attach"})
    quiescence = {
        "powerSource": power_state.get("powerSource", {"available": False}),
        "lowPowerMode": power_state.get("lowPowerMode", {"available": False}),
        "thermalWarning": power_state.get("thermalWarning", {"available": False}),
        "colorSpace": display["colorSpace"],
        "displayRefreshMilliHertz": display["maximumRefreshMilliHertz"],
        "ownershipClean": ownership_clean,
        "strayProcessCount": len(strays),
    }
    checks = {"build": True, "validity": valid,
              "quiescence": ownership_clean and len(strays) == 0}
    return {
        "schemaVersion": 3,
        "run": {
            "identity": "profiling-attach",
            "startedAtUtc": started,
            "completedAtUtc": completed,
            "operator": args.operator,
            "agentRole": args.agent_role,
            "purpose": "profiling",
            "sourceSha256": source_sha,
            "binarySha256": binary_sha,
            "workload": manifest["workload"] if set(manifest["workload"]) == {"identity", "version"}
                        else {"identity": manifest["workload"]["identity"],
                              "version": manifest["workload"]["version"]},
            "manifestSha256": contract.manifest_hash(manifest),
            "assets": manifest["assets"],
            "inputs": manifest["inputs"],
            "seed": manifest["seed"],
        },
        "candidate": {
            "identity": "installed-fresco-scene",
            "backend": args.backend,
            "graphicsApi": args.graphics_api,
            "shaderApi": args.shader_api,
        },
        "criteriaVersion": manifest["criteriaVersion"],
        "build": {
            "identity": "attached-installed-binary",
            "sourceSha256": source_sha,
            "binarySha256": binary_sha,
            "commands": ["attach installed fresco-scene binary"],
            "artifacts": ["build-log"],
        },
        "host": {"os": host.get("cpuBrand") or "macOS", "architecture": "arm64"},
        "display": display,
        "policy": {"revision": 1, "fpsCeiling": 60, "active": True,
                   "schedulerMode": "attached-live"},
        "profile": {
            "validity": valid,
            "invalidReasons": reasons,
            "trialOrder": BRACKET,
            "quiescenceManifest": quiescence,
            "metrics": metrics,
            "rawArtifacts": ["powermetrics-raw"],
        },
        "artifacts": [powermetrics_artifact, build_artifact],
        "verdict": {
            "accepted": valid and all(checks.values()),
            "criteriaVersion": manifest["criteriaVersion"],
            "checks": checks,
            "failures": [] if valid else list(reasons),
        },
    }


def _summary(record, metrics, reasons, valid, extras):
    def show(key, unit="", scale=1.0):
        field = metrics[key]
        return f"{field['value'] * scale:.1f}{unit}" if field["available"] else "unavailable"
    cputime = extras.get("cputimeMsPerSecond")
    cputime_str = f"{cputime:.1f} ms/s  (~{cputime / 10:.1f}% of one core)" if cputime is not None else "unavailable"
    lines = [
        "",
        "=== profiling summary (result version 3) ===",
        f"validity        : {valid}  reasons: {', '.join(reasons) or 'none'}",
        f"cpu power (sys) : {show('cpuPowerMilliwatts', ' mW')}",
        f"gpu power (sys) : {show('gpuPowerMilliwatts', ' mW')}",
        f"gpu residency   : {show('gpuActiveResidency', '%', 100.0)}",
        f"fresco cputime  : {cputime_str}",
        f"fresco wakeups  : {show('wakeups')} (per window)",
        f"energy impact   : {show('energyImpact')}",
        f"target rss      : {metrics['memoryBytes']['value'] / 1e6:.1f} MB",
        "",
        "priority read: cpu/gpu power are system-wide; fresco cputime and wakeups",
        "are scoped to its process tree. high gpu power + residency with modest",
        "fresco cputime points at rendering -> the backend question. high fresco",
        "cputime/wakeups with low gpu points at scheduling/occlusion.",
    ]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Result-version-3 profiling runner.")
    parser.add_argument("--store", default=str(pathlib.Path(tempfile.gettempdir()) / "fresco-profiling-dev"))
    parser.add_argument("--binary", default=str(DEFAULT_BINARY))
    parser.add_argument("--backend", default="native-opengl")
    parser.add_argument("--graphics-api", default="opengl")
    parser.add_argument("--shader-api", default="glsl")
    parser.add_argument("--operator", default="astral")
    parser.add_argument("--agent-role", default="root-agent", choices=sorted(contract.ROLES))
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--interval-ms", type=int, default=500)
    parser.add_argument("--attach", action="store_true", default=True)
    parser.add_argument("--dev-selftest", action="store_true")
    args = parser.parse_args()
    # The contract store opener refuses symlinked path components, and the
    # macOS temp dir lives under /var -> /private/var. Resolve to a physical path.
    args.store = os.path.realpath(args.store)
    pathlib.Path(args.store).mkdir(parents=True, exist_ok=True)

    record, metrics, reasons, valid, _, extras = run(args)
    contract.validate_result(record, artifact_root=pathlib.Path(args.store))
    payload = contract.canonical_json_bytes(record)
    digest = hashlib.sha256(payload).hexdigest()
    records_dir = pathlib.Path(args.store) / "records-dev"
    records_dir.mkdir(parents=True, exist_ok=True)
    (records_dir / f"{digest}.json").write_bytes(payload)
    print(_summary(record, metrics, reasons, valid, extras))
    print(f"\nrecord validated and written: {records_dir / (digest + '.json')}")


if __name__ == "__main__":
    main()
