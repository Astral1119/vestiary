#!/usr/bin/env python3

import copy
import datetime
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures" / "state"


def type_matches(value, expected):
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    raise AssertionError(f"unsupported schema type: {expected}")


def resolve_ref(root, reference):
    assert reference.startswith("#/"), f"unsupported reference: {reference}"
    value = root
    for token in reference[2:].split("/"):
        value = value[token.replace("~1", "/").replace("~0", "~")]
    return value


def schema_errors(value, schema, root, path="$"):
    if "$ref" in schema:
        return schema_errors(value, resolve_ref(root, schema["$ref"]), root, path)

    errors = []
    if "const" in schema and value != schema["const"]:
        errors.append(f"{path}: expected constant {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: value is outside the enum")
    if "oneOf" in schema:
        matches = [not schema_errors(value, branch, root, path) for branch in schema["oneOf"]]
        if sum(matches) != 1:
            errors.append(f"{path}: expected exactly one schema branch")
    if "anyOf" in schema:
        matches = [not schema_errors(value, branch, root, path) for branch in schema["anyOf"]]
        if not any(matches):
            errors.append(f"{path}: expected at least one schema branch")
    for branch in schema.get("allOf", []):
        errors.extend(schema_errors(value, branch, root, path))
    if "if" in schema and not schema_errors(value, schema["if"], root, path):
        if "then" in schema:
            errors.extend(schema_errors(value, schema["then"], root, path))

    expected_type = schema.get("type")
    if expected_type and not type_matches(value, expected_type):
        errors.append(f"{path}: expected {expected_type}")
        return errors

    if isinstance(value, dict):
        properties = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing required property {key!r}")
        if schema.get("additionalProperties") is False:
            for key in value.keys() - properties.keys():
                errors.append(f"{path}: additional property {key!r}")
        if len(value) < schema.get("minProperties", 0):
            errors.append(f"{path}: too few properties")
        for key, child in value.items():
            if key in properties:
                errors.extend(schema_errors(child, properties[key], root, f"{path}.{key}"))

    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            errors.append(f"{path}: too few items")
        if schema.get("uniqueItems"):
            encoded = [json.dumps(item, sort_keys=True) for item in value]
            if len(encoded) != len(set(encoded)):
                errors.append(f"{path}: duplicate items")
        if "items" in schema:
            for index, item in enumerate(value):
                errors.extend(schema_errors(item, schema["items"], root, f"{path}[{index}]"))

    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            errors.append(f"{path}: string is too short")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            errors.append(f"{path}: string does not match {schema['pattern']!r}")
        if schema.get("format") == "date-time":
            try:
                datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
            except ValueError:
                errors.append(f"{path}: invalid date-time")

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path}: value is below minimum")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path}: value is above maximum")
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            errors.append(f"{path}: value is below exclusive minimum")
    return errors


def duplicate_errors(items, label, path):
    identities = [item["id"] for item in items]
    return [
        f"{path}: duplicate {label} ID {identity!r}"
        for identity in sorted(set(identities))
        if identities.count(identity) > 1
    ]


def binding_errors(binding, playlist_ids, path):
    if binding["kind"] == "playlist" and binding["playlistId"] not in playlist_ids:
        return [f"{path}: unknown playlist ID {binding['playlistId']!r}"]
    return []


def layout_errors(layout, playlist_ids, display_ids, path):
    errors = []
    if layout["mode"] == "perDisplay":
        assigned_ids = [item["displayId"] for item in layout["assignments"]]
        for display_id in sorted(set(assigned_ids)):
            if assigned_ids.count(display_id) > 1:
                errors.append(f"{path}: duplicate display ID {display_id!r}")
            if display_id not in display_ids:
                errors.append(f"{path}: unknown display ID {display_id!r}")
        for index, assignment in enumerate(layout["assignments"]):
            errors.extend(binding_errors(
                assignment["binding"], playlist_ids,
                f"{path}.assignments[{index}].binding",
            ))
        if "defaultBinding" in layout:
            errors.extend(binding_errors(layout["defaultBinding"], playlist_ids, f"{path}.defaultBinding"))
    else:
        errors.extend(binding_errors(layout["binding"], playlist_ids, f"{path}.binding"))
    return errors


def state_semantic_errors(state):
    errors = []
    errors.extend(duplicate_errors(state["displays"], "display", "$.displays"))
    errors.extend(duplicate_errors(state["playlists"], "playlist", "$.playlists"))
    errors.extend(duplicate_errors(state["profiles"], "profile", "$.profiles"))
    errors.extend(duplicate_errors(state["applicationRules"], "rule", "$.applicationRules"))

    display_ids = {item["id"] for item in state["displays"]}
    playlist_ids = {item["id"] for item in state["playlists"]}
    profile_ids = {item["id"] for item in state["profiles"]}
    for index, playlist in enumerate(state["playlists"]):
        errors.extend(duplicate_errors(playlist["entries"], "entry", f"$.playlists[{index}].entries"))
    for index, profile in enumerate(state["profiles"]):
        errors.extend(layout_errors(
            profile["layout"], playlist_ids, display_ids,
            f"$.profiles[{index}].layout",
        ))
    for index, rule in enumerate(state["applicationRules"]):
        profile_id = rule["effect"].get("profileId")
        if rule["scope"]["kind"] == "affectedDisplays" and profile_id is not None:
            errors.append(
                f"$.applicationRules[{index}].effect: affected-display rule "
                "cannot select a profile"
            )
        if profile_id and profile_id not in profile_ids:
            errors.append(f"$.applicationRules[{index}]: unknown profile ID {profile_id!r}")
    desired = state["desired"]
    if desired.get("profileId") is not None and desired["profileId"] not in profile_ids:
        errors.append(f"$.desired: unknown profile ID {desired['profileId']!r}")
    if "layout" in desired:
        errors.extend(layout_errors(desired["layout"], playlist_ids, display_ids, "$.desired.layout"))
    return errors


def status_semantic_errors(status, state):
    errors = []
    if status["desiredRevision"] > state["revision"]:
        errors.append("$.desiredRevision: exceeds durable state revision")
    status_is_current = status["desiredRevision"] == state["revision"]
    playlist_entries = {
        playlist["id"]: {entry["id"] for entry in playlist["entries"]}
        for playlist in state["playlists"]
    }
    profile_ids = {profile["id"] for profile in state["profiles"]}
    observed_ids = [display["id"] for display in status["observed"]["displays"]]
    effective_ids = [display["displayId"] for display in status["effective"]["displays"]]
    runtime_ids = [display["displayId"] for display in status["runtime"]["displays"]]

    if len(observed_ids) != len(set(observed_ids)):
        errors.append("$.observed.displays: duplicate display ID")
    if len(effective_ids) != len(set(effective_ids)):
        errors.append("$.effective.displays: duplicate display ID")
    if len(runtime_ids) != len(set(runtime_ids)):
        errors.append("$.runtime.displays: duplicate display ID")
    connected_ids = {
        display["id"] for display in status["observed"]["displays"]
        if display["connected"]
    }
    for index, display in enumerate(status["effective"]["displays"]):
        path = f"$.effective.displays[{index}]"
        if display["displayId"] not in connected_ids:
            errors.append(f"{path}: display is not connected")
        if status_is_current:
            errors.extend(binding_errors(display["binding"], playlist_entries.keys(), f"{path}.binding"))
        for name in ("paused", "muted", "hidden"):
            if display[name] != bool(display["reasons"][name]):
                errors.append(f"{path}.{name}: does not match its reasons")
        has_fps = "fpsCeiling" in display
        if has_fps != bool(display["reasons"]["fpsCeiling"]):
            errors.append(f"{path}.fpsCeiling: does not match its reasons")
    active_profile = status["effective"].get("activeProfile")
    if status_is_current and active_profile and active_profile["profileId"] not in profile_ids:
        errors.append(f"$.effective.activeProfile: unknown profile ID {active_profile['profileId']!r}")
    for index, checkpoint in enumerate(status["runtime"]["playlistCheckpoints"]):
        playlist_id = checkpoint["playlistId"]
        if not status_is_current:
            continue
        if playlist_id not in playlist_entries:
            errors.append(f"$.runtime.playlistCheckpoints[{index}]: unknown playlist ID {playlist_id!r}")
        elif checkpoint["entryId"] not in playlist_entries[playlist_id]:
            errors.append(f"$.runtime.playlistCheckpoints[{index}]: unknown entry ID {checkpoint['entryId']!r}")
    for index, display_id in enumerate(runtime_ids):
        if display_id not in effective_ids:
            errors.append(f"$.runtime.displays[{index}]: display is outside effective status")
    return errors


def validate_state(state, schema):
    structural = schema_errors(state, schema, schema)
    return structural or state_semantic_errors(state)


def validate_status(status, schema, state):
    structural = schema_errors(status, schema, schema)
    return structural or status_semantic_errors(status, state)


def pointer_parent(document, pointer):
    tokens = [token.replace("~1", "/").replace("~0", "~") for token in pointer.split("/")[1:]]
    parent = document
    for token in tokens[:-1]:
        parent = parent[int(token)] if isinstance(parent, list) else parent[token]
    return parent, tokens[-1]


def apply_case(base, case):
    candidate = copy.deepcopy(base)
    operation = case.get("append") or case["replace"]
    parent, key = pointer_parent(candidate, operation["pointer"])
    if "append" in case:
        target = parent[int(key)] if isinstance(parent, list) else parent[key]
        target.append(operation["value"])
    elif isinstance(parent, list):
        parent[int(key)] = operation["value"]
    else:
        parent[key] = operation["value"]
    return candidate


def main():
    state_schema = json.loads((ROOT / "schema" / "state.schema.json").read_text())
    status_schema = json.loads((ROOT / "schema" / "status.schema.json").read_text())
    states = {}
    for path in sorted((FIXTURES / "valid").glob("*.json")):
        state = json.loads(path.read_text())
        errors = validate_state(state, state_schema)
        assert not errors, f"{path.name} rejected:\n" + "\n".join(errors)
        states[path.name] = state

    statuses = {}
    for path in sorted((FIXTURES / "status").glob("*.json")):
        status = json.loads(path.read_text())
        state = states[path.name]
        errors = validate_status(status, status_schema, state)
        assert not errors, f"status/{path.name} rejected:\n" + "\n".join(errors)
        statuses[path.name] = status

    legacy = (FIXTURES / "legacy-current.txt").read_text().strip()
    migrated = states["migrated-legacy.json"]
    assert migrated["revision"] == 1
    assert migrated["desired"]["layout"]["binding"]["target"] == legacy

    invalid_paths = sorted((FIXTURES / "invalid").glob("*.json"))
    for path in invalid_paths:
        case = json.loads(path.read_text())
        if case["schema"] == "state":
            candidate = apply_case(states[case["base"]], case)
            errors = validate_state(candidate, state_schema)
        else:
            candidate = apply_case(statuses[case["base"]], case)
            errors = validate_status(candidate, status_schema, states[case["base"]])
        assert errors, f"{path.name} was accepted"
        assert any(case["error"] in error for error in errors), (
            f"{path.name} did not report {case['error']!r}:\n" + "\n".join(errors)
        )

    print(
        f"state contract: {len(states)} durable, {len(statuses)} status, "
        f"{len(invalid_paths)} invalid fixtures passed"
    )


if __name__ == "__main__":
    main()
