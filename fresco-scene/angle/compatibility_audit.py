#!/usr/bin/env python3

import argparse
import pathlib
import re
import subprocess
import sys


LINUX_WALLPAPERENGINE_REVISION = "b016d7d1fdcf4e5fd2f9c9fa420a8aaa07fee02d"

DESKTOP_ONLY_CALLS = {
    "glGetnTexImage": "replace texture readback with an FBO plus glReadPixels",
    "glUniform1d": "retarget double uniforms to float",
    "glUniform1dv": "retarget double uniform arrays to float",
}

REQUIRES_EXTENSION_OR_GUARD = {
    "glObjectLabel": "GL_KHR_debug",
    "glPopDebugGroup": "GL_KHR_debug",
    "glPushDebugGroup": "GL_KHR_debug",
    "glReadnPixels": "GL_KHR_robustness",
}

DESKTOP_ONLY_CONSTANTS = {
    "GL_BGRA": "use GL_BGRA_EXT only when exposed, or upload RGBA",
    "GL_CLAMP_TO_BORDER": "emulate the border or require GL_EXT_texture_border_clamp",
    "GL_DEPTH_CLAMP": "remove or require GL_EXT_depth_clamp",
    "GL_TEXTURE_MAX_ANISOTROPY": "use the EXT token only when exposed",
}

SHADER_PATTERNS = {
    r"#version\s+330(?:\s+core)?": "emit #version 300 es and ES precision qualifiers",
    r"#version\s+410(?:\s+core)?": "emit #version 300 es and ES precision qualifiers",
    r"\blayout\s*\(\s*binding\s*=": "remove desktop binding qualifiers for ES 3.0",
}


def source_files(root: pathlib.Path):
    renderer_root = pathlib.Path(__file__).resolve().parents[1] / "renderer"
    cmake = (renderer_root / "CMakeLists.txt").read_text()
    relative_sources = set(re.findall(r"\$\{upstream\}/([^\s)]+\.(?:cpp|h))", cmake))
    for relative_source in sorted(relative_sources):
        path = root / relative_source
        if path.is_file():
            yield path
    yield from (renderer_root / "src").glob("*.cpp")
    yield from (renderer_root / "src").glob("*.mm")


def matches(files, pattern):
    expression = re.compile(pattern)
    found = []
    for path in files:
        for line_number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            if expression.search(line):
                found.append(f"{path}:{line_number}")
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description="audit the pinned scene core for GLES 3.0 blockers")
    parser.add_argument("upstream", type=pathlib.Path)
    args = parser.parse_args()
    root = args.upstream.resolve()
    if not (root / "src/WallpaperEngine/Render").is_dir():
        parser.error(f"not a linux-wallpaperengine checkout: {root}")
    revision = subprocess.run(
        ["git", "-C", root, "rev-parse", "HEAD"],
        capture_output=True,
        check=False,
        text=True,
    ).stdout.strip()
    if revision != LINUX_WALLPAPERENGINE_REVISION:
        parser.error(
            "audit requires linux-wallpaperengine "
            f"{LINUX_WALLPAPERENGINE_REVISION}; found {revision or 'no git revision'}"
        )

    files = list(source_files(root))
    print(f"upstream revision: {revision}")
    blockers = 0
    print("desktop-only calls:")
    for call, action in DESKTOP_ONLY_CALLS.items():
        locations = matches(files, rf"\b{call}\s*\(")
        if locations:
            blockers += len(locations)
            print(f"  {call}: {len(locations)}; {action}")

    print("extension guards:")
    for call, extension in REQUIRES_EXTENSION_OR_GUARD.items():
        locations = matches(files, rf"\b{call}\s*\(")
        if locations:
            print(f"  {call}: {len(locations)}; require {extension}")

    print("desktop-only constants:")
    for constant, action in DESKTOP_ONLY_CONSTANTS.items():
        locations = matches(files, rf"\b{constant}\b")
        if locations:
            blockers += len(locations)
            print(f"  {constant}: {len(locations)}; {action}")

    print("shader retargeting:")
    for pattern, action in SHADER_PATTERNS.items():
        locations = matches(files, pattern)
        if locations:
            blockers += len(locations)
            print(f"  {pattern}: {len(locations)}; {action}")

    print(f"blocking occurrences: {blockers}")
    return 1 if blockers else 0


if __name__ == "__main__":
    sys.exit(main())
