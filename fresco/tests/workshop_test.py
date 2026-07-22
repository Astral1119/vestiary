#!/usr/bin/env python3
import os
import runpy
import subprocess
from unittest import mock


ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORKSHOP = os.path.join(ROOT, "fresco", "workshop")
LIVERYCTL = os.path.join(ROOT, "livery", "liveryctl")
module = runpy.run_path(WORKSHOP)

assert module["LIVERYCTL"] == LIVERYCTL
assert os.access(LIVERYCTL, os.X_OK)

completed = subprocess.CompletedProcess([], 0, stdout='{"id":"fixture"}\n', stderr="")
with mock.patch.object(module["subprocess"], "run", return_value=completed) as run:
    result = module["import_wallpaper"]("frame.png", "Title", "Credit", "/live")

assert result.returncode == 0
arguments = run.call_args.args[0]
assert arguments == [
    LIVERYCTL,
    "import-wallpaper",
    "frame.png",
    "--name",
    "Title",
    "--subtitle",
    "Wallpaper Engine",
    "--credit",
    "Credit",
    "--live",
    "/live",
]
print("Workshop ingestion checks passed")
