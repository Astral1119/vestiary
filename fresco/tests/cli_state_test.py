#!/usr/bin/env python3

import importlib.util
import json
import os
import signal
import sys
from importlib.machinery import SourceFileLoader


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOADER = SourceFileLoader("fresco_state_cli", os.path.join(ROOT, "fresco"))
SPEC = importlib.util.spec_from_loader("fresco_state_cli", LOADER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load fresco CLI")
FRESCO = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(FRESCO)


class CompletedTransaction:
    def __init__(self, response):
        self.returncode = 0
        self.stdout = json.dumps(response)
        self.stderr = ""


def expect_failure(callback, text):
    try:
        callback()
    except SystemExit as error:
        assert text in str(error), error
        return
    raise AssertionError("expected bounded convergence failure")


state_dir = os.environ["FRESCO_STATE_DIR"]
status_path = os.path.join(state_dir, "status.json")
FRESCO.STATUS = status_path
FRESCO.runtime_pid = lambda: 1234

original_build = FRESCO.build
original_run = FRESCO.subprocess.run
FRESCO.build = lambda: None
transaction_commands = []
FRESCO.subprocess.run = lambda command, **kwargs: (
    transaction_commands.append(command)
    or CompletedTransaction({"revision": 17, "muted": True})
)
try:
    assert FRESCO.state_selection("fixture", "/resolved/fixture") == 17
    assert FRESCO.state_muted(None) == (17, True)
finally:
    FRESCO.build = original_build
    FRESCO.subprocess.run = original_run
assert transaction_commands == [
    [FRESCO.BIN, "--state-select", "fixture", "/resolved/fixture"],
    [FRESCO.BIN, "--state-muted", "toggle"],
], transaction_commands

with open(status_path, "w") as handle:
    json.dump({
        "desiredRevision": 7,
        "runtime": {"status": "running", "displays": []},
    }, handle)
status = FRESCO.wait_for_revision(7, attempts=1)
assert status["desiredRevision"] == 7

with open(status_path, "w") as handle:
    json.dump({
        "desiredRevision": 8,
        "runtime": {
            "status": "degraded",
            "displays": [{"error": "fixture degraded"}],
        },
    }, handle)
expect_failure(
    lambda: FRESCO.wait_for_revision(8, attempts=1),
    "fixture degraded")

FRESCO.runtime_pid = lambda: None
expect_failure(
    lambda: FRESCO.wait_for_revision(9, attempts=1),
    "timed out")

calls = []
FRESCO.resolve = lambda target: "/resolved/wallpaper"
FRESCO.load_project = lambda path: {}
FRESCO.state_selection = lambda target=None, legacy_path=None: (
    calls.append(("transaction", target, legacy_path)) or 11)
FRESCO.runtime_pid = lambda: 4321
FRESCO.runtime_stale = lambda pid: False
FRESCO.wait_for_revision = lambda revision: calls.append(("wait", revision))
original_kill = os.kill
os.kill = lambda pid, sent_signal: calls.append(("signal", pid, sent_signal))
try:
    FRESCO.set_wallpaper("relative-wallpaper")
finally:
    os.kill = original_kill
assert calls == [
    ("transaction", "relative-wallpaper", "/resolved/wallpaper"),
    ("signal", 4321, signal.SIGUSR1),
    ("wait", 11),
], calls

calls = []
FRESCO.state_muted = lambda muted=None: (
    calls.append(("transaction", muted)) or (12, True))
FRESCO.runtime_pid = lambda: 4321
FRESCO.wait_for_revision = lambda revision: calls.append(("wait", revision))
os.kill = lambda pid, sent_signal: calls.append(("signal", pid, sent_signal))
try:
    FRESCO.set_muted()
finally:
    os.kill = original_kill
assert calls == [
    ("transaction", None),
    ("signal", 4321, signal.SIGUSR1),
    ("wait", 12),
], calls

print("Fresco state CLI convergence checks passed")
