#!/usr/bin/env python3

import argparse
import pathlib

import adapter
import lifecycle_adapter


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--helper", required=True, type=pathlib.Path)
    parser.add_argument("--assets", required=True, type=pathlib.Path)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--backend", required=True)
    parser.add_argument("--store", required=True, type=pathlib.Path)
    parser.add_argument("--source-manifest", required=True, type=pathlib.Path)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--build-identity", required=True)
    parser.add_argument("--build-command", action="append", required=True)
    parser.add_argument("--operator", required=True)
    parser.add_argument("--agent-role", required=True)
    parser.add_argument("--timeout", type=float, default=30.0)
    arguments = parser.parse_args()
    configuration = adapter.CandidateConfiguration(
        helper_binary=adapter.normalize_wrapper_path(arguments.helper),
        asset_root=adapter.normalize_wrapper_path(arguments.assets),
        expected_candidate=arguments.candidate,
        expected_backend=arguments.backend,
        store_root=adapter.normalize_wrapper_path(arguments.store),
        source_manifest=adapter.normalize_wrapper_path(arguments.source_manifest),
        source_sha256=arguments.source_sha256,
        build_identity=arguments.build_identity,
        build_commands=tuple(arguments.build_command),
        operator=arguments.operator,
        agent_role=arguments.agent_role,
        timeout_seconds=arguments.timeout,
    )
    record, path = lifecycle_adapter.run_lifecycle(configuration)
    print(path)
    print(record["verdict"]["accepted"])


if __name__ == "__main__":
    main()
