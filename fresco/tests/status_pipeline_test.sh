#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fresco-status-pipeline-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

swiftc \
  -O \
  -warnings-as-errors \
  -framework AppKit \
  "$ROOT/FrescoStatePlanner.swift" \
  "$ROOT/RuntimeAssignments.swift" \
  "$ROOT/FrescoObservation.swift" \
  "$ROOT/FrescoStatusPipeline.swift" \
  "$ROOT/tests/FrescoStatusPipelineTests.swift" \
  -o "$TMP/fresco-status-pipeline-tests"

"$TMP/fresco-status-pipeline-tests" "$TMP/output"

python3 - "$ROOT" "$TMP/output/state.json" "$TMP/output/status.json" <<'PY'
import importlib.util
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "state_contract_test", root / "tests" / "state_contract_test.py")
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)
state_schema = json.loads((root / "schema" / "state.schema.json").read_text())
status_schema = json.loads((root / "schema" / "status.schema.json").read_text())
state = json.loads(pathlib.Path(sys.argv[2]).read_text())
status = json.loads(pathlib.Path(sys.argv[3]).read_text())
state_errors = contract.validate_state(state, state_schema)
status_errors = contract.validate_status(status, status_schema, state)
assert not state_errors, "generated state rejected:\n" + "\n".join(state_errors)
assert not status_errors, "generated status rejected:\n" + "\n".join(status_errors)
print("generated Fresco status passed schema and semantic validation")
PY
