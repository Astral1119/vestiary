#!/usr/bin/env python3

"""Check that no scene script keeps or writes to the user-property object.

The script engine builds one user-property object per tick and hands the same
one to every generic property script, rather than rebuilding it per script. That
is only sound while no script retains or mutates what it receives: with a fresh
object per call a mutation is discarded, and with a shared one it would persist
across scripts and ticks.

The non-graph wrapper copies out with Object.assign and cannot be a problem. The
graph wrapper hands the object straight to the author's applyUserProperties,
which is arbitrary workshop code, so the guarantee is a fact about the installed
corpus rather than anything the engine enforces. This re-establishes it.

Measured 2026-07-29 over 27 installed packages: 14 carry a scene, holding 652
scripted values, of which 6 receive the object and none retain or mutate it.

Run this before widening how the shared object is used, and before trusting the
sharing on a corpus this has not seen. A hit is not automatically a defect — read
the body and decide whether the write escapes — but it does mean the sharing in
SceneScriptEngine.cpp needs re-argued.

Usage:

    tools/user-property-sharing-survey/survey.py [workshop-dir]

Exits non-zero if any script retains or mutates the object it is given.
"""

import json
import os
import re
import struct
import sys


DEFAULT_WORKSHOP = os.path.expanduser(
    "~/Library/Application Support/Steam/steamapps/workshop/content/431960"
)

# Ways the parameter could outlive the call or be written through. Each is
# deliberately broad: a false positive costs one reading of the body, and a
# false negative silently invalidates the sharing.
ESCAPES = [
    (r"\b{a}\s*\.\s*\w+\s*(?:[-+*/|&^]|\*\*|<<|>>>?)?=(?!=)", "property assign"),
    (r"\b{a}\s*\[[^\]]+\]\s*(?:[-+*/|&^]|\*\*|<<|>>>?)?=(?!=)", "index assign"),
    (r"\bdelete\s+{a}\b", "delete"),
    (r"\b\w+\s*=\s*{a}\s*[;,)\n]", "retained in a variable"),
    (r"Object\.assign\s*\(\s*{a}\b", "Object.assign target"),
    (r"\b{a}\s*\.\s*(?:push|pop|sort|splice|reverse|fill)\b", "mutating method"),
]


def read_scene(directory):
    """Return a package's scene.json, from scene.pkg or beside it."""
    loose = os.path.join(directory, "scene.json")
    if os.path.exists(loose):
        with open(loose) as handle:
            return json.load(handle)

    package = os.path.join(directory, "scene.pkg")
    if not os.path.exists(package):
        return None

    def read_u32(handle):
        return struct.unpack("<I", handle.read(4))[0]

    def read_string(handle):
        return handle.read(read_u32(handle)).decode("utf-8")

    with open(package, "rb") as handle:
        read_string(handle)
        entries = [
            (read_string(handle), read_u32(handle), read_u32(handle))
            for _ in range(read_u32(handle))
        ]
        base = handle.tell()
        entry = next((e for e in entries if e[0] == "scene.json"), None)
        if entry is None:
            return None
        handle.seek(base + entry[1])
        return json.loads(handle.read(entry[2]))


def scripted_values(value, path=()):
    if isinstance(value, dict):
        if isinstance(value.get("script"), str):
            yield path, value["script"]
        for key, child in value.items():
            if key != "script":
                yield from scripted_values(child, path + (str(key),))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from scripted_values(child, path + (str(index),))


def escapes(source, parameter):
    """Name the way this source lets the parameter escape, or None."""
    if not re.fullmatch(r"[A-Za-z_$][\w$]*", parameter):
        # A destructured or defaulted parameter is not something this can read.
        return "parameter is not a plain name"
    for pattern, reason in ESCAPES:
        if re.search(pattern.format(a=re.escape(parameter)), source):
            return reason
    return None


def main():
    workshop = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_WORKSHOP
    if not os.path.isdir(workshop):
        raise SystemExit(f"workshop directory not found: {workshop}")

    packages = scenes = values = 0
    receivers = []

    for identifier in sorted(os.listdir(workshop)):
        directory = os.path.join(workshop, identifier)
        if not os.path.isdir(directory):
            continue
        packages += 1
        try:
            scene = read_scene(directory)
        except (OSError, ValueError, struct.error) as error:
            print(f"  ! {identifier}: unreadable ({error})", file=sys.stderr)
            continue
        if scene is None:
            continue
        scenes += 1

        for path, source in scripted_values(scene):
            values += 1
            signature = re.search(
                r"function\s+applyUserProperties\s*\(([^)]*)\)", source
            )
            if signature is None:
                continue
            parameter = signature.group(1).strip()
            receivers.append(
                (identifier, "/".join(path), parameter, escapes(source, parameter))
            )

    leaking = [r for r in receivers if r[3] is not None]

    print(f"packages scanned         : {packages}")
    print(f"packages carrying a scene: {scenes}")
    print(f"scripted values          : {values}")
    print(f"receive user properties  : {len(receivers)}")
    print(f"retain or mutate         : {len(leaking)}")
    print()
    for identifier, path, parameter, reason in receivers:
        print(
            f"  {identifier:>12}  {path:<28} "
            f"{parameter:<24} {reason or 'read-only'}"
        )

    if leaking:
        print()
        print(
            "The shared user-property object in SceneScriptEngine.cpp assumes "
            "none of these\nretain or mutate it. Read the bodies above and "
            "re-argue the sharing before shipping."
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
