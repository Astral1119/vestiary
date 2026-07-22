#!/usr/bin/env python3

import argparse
import hashlib
import json
import pathlib
import subprocess


ROOT_FILES = (
    "CMakeLists.txt",
    "PROTOCOL.md",
    "renderer/CMakeLists.txt",
    "renderer/PuppetIntegration.cmake",
)
SOURCE_DIRECTORIES = (
    "include",
    "src",
    "renderer/cmake",
    "renderer/compat",
    "renderer/include",
    "renderer/src",
    "renderer/tests",
    "tests",
    "tools/common-harness",
)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_bytes(value):
    return json.dumps(
        value, ensure_ascii=False, allow_nan=False, separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def source_files(root):
    paths = [root / relative for relative in ROOT_FILES]
    for directory in SOURCE_DIRECTORIES:
        paths.extend(
            path for path in (root / directory).rglob("*")
            if path.is_file() and "__pycache__" not in path.parts
            and path.suffix != ".pyc"
        )
    return sorted(set(paths), key=lambda path: path.relative_to(root).as_posix())


def validate_pinned_checkout(name, path, expected_commit, required_submodules=()):
    path = path.resolve(strict=True)

    def git(*arguments):
        completed = subprocess.run(
            ["git", "-C", str(path), *arguments],
            capture_output=True,
            text=True,
            check=False,
        )
        if completed.returncode != 0:
            raise ValueError(f"cannot inspect pinned {name} checkout")
        return completed.stdout.rstrip("\n")

    if git("rev-parse", "HEAD") != expected_commit:
        raise ValueError(f"pinned {name} checkout commit drift")
    if git("status", "--porcelain", "--untracked-files=no", "--ignore-submodules=all"):
        raise ValueError(f"pinned {name} checkout has tracked modifications")
    for relative in required_submodules:
        status_result = subprocess.run(
            ["git", "-C", str(path), "submodule", "status", "--", relative],
            capture_output=True,
            text=True,
            check=False,
        )
        status = status_result.stdout.rstrip("\n")
        if status_result.returncode != 0 or not status or status[0] != " ":
            raise ValueError(f"pinned {name} required submodule is not exact: {relative}")
        submodule = path / relative
        completed = subprocess.run(
            ["git", "-C", str(submodule), "status", "--porcelain",
             "--untracked-files=no", "--ignore-submodules=all"],
            capture_output=True,
            text=True,
            check=False,
        )
        if completed.returncode != 0 or completed.stdout.strip():
            raise ValueError(
                f"pinned {name} required submodule is dirty: {relative}"
            )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--digest-output", type=pathlib.Path)
    parser.add_argument("--backend", required=True)
    parser.add_argument("--renderer-commit", required=True)
    parser.add_argument("--glm-commit", required=True)
    parser.add_argument("--angle-revision", required=True)
    parser.add_argument("--compiler-id", required=True)
    parser.add_argument("--compiler-version", required=True)
    parser.add_argument("--system-name", required=True)
    parser.add_argument("--system-version", required=True)
    parser.add_argument("--system-processor", required=True)
    parser.add_argument("--deployment-target", default="")
    parser.add_argument("--generator", required=True)
    parser.add_argument("--build-type", default="")
    parser.add_argument("--external-file", nargs=2, action="append", default=[])
    parser.add_argument("--pinned-checkout", nargs=3, action="append", default=[])
    parser.add_argument("--required-renderer-submodule", action="append", default=[])
    arguments = parser.parse_args()

    root = arguments.source_root.resolve(strict=True)
    for name, path, commit in arguments.pinned_checkout:
        validate_pinned_checkout(
            name,
            pathlib.Path(path),
            commit,
            arguments.required_renderer_submodule if name == "renderer" else (),
        )
    files = [
        {
            "path": path.relative_to(root).as_posix(),
            "sha256": sha256(path),
        }
        for path in source_files(root)
    ]
    external_files = []
    external_names = set()
    for logical, physical in sorted(arguments.external_file):
        logical_path = pathlib.PurePosixPath(logical)
        if logical_path.is_absolute() or ".." in logical_path.parts:
            raise ValueError("external file identity must be a logical relative path")
        if logical in external_names:
            raise ValueError(f"duplicate external file identity: {logical}")
        external_names.add(logical)
        external_files.append({
            "path": logical,
            "sha256": sha256(pathlib.Path(physical).resolve(strict=True)),
        })
    manifest = {
        "schemaVersion": 1,
        "files": files,
        "dependencies": {
            "angleRevision": arguments.angle_revision,
            "glmCommit": arguments.glm_commit,
            "rendererCommit": arguments.renderer_commit,
        },
        "externalFiles": external_files,
        "build": {
            "backend": arguments.backend,
            "buildType": arguments.build_type,
            "compiler": {
                "id": arguments.compiler_id,
                "version": arguments.compiler_version,
            },
            "deploymentTarget": arguments.deployment_target,
            "generator": arguments.generator,
            "system": {
                "name": arguments.system_name,
                "processor": arguments.system_processor,
                "version": arguments.system_version,
            },
        },
    }
    payload = canonical_bytes(manifest)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_bytes(payload)
    digest = hashlib.sha256(payload).hexdigest()
    if arguments.digest_output is not None:
        arguments.digest_output.parent.mkdir(parents=True, exist_ok=True)
        arguments.digest_output.write_text(digest, encoding="ascii")
    print(digest)


if __name__ == "__main__":
    main()
