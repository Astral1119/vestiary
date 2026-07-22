#!/usr/bin/env python3

import argparse
import pathlib

import adapter
import contract


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Produce one manifest-bound candidate correctness record."
    )
    parser.add_argument(
        "workload", choices=sorted(adapter.SUPPORTED_WORKLOADS)
    )
    parser.add_argument("--helper", required=True, type=pathlib.Path)
    parser.add_argument("--asset-root", required=True, type=pathlib.Path)
    parser.add_argument("--expected-candidate", required=True)
    parser.add_argument("--expected-backend", required=True)
    parser.add_argument("--store", required=True, type=pathlib.Path)
    parser.add_argument("--source-manifest", required=True, type=pathlib.Path)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--build-identity", required=True)
    parser.add_argument("--build-command", required=True, action="append")
    parser.add_argument("--operator", required=True)
    parser.add_argument("--agent-role", required=True, choices=sorted(contract.ROLES))
    parser.add_argument("--media-fixture-generator", type=pathlib.Path)
    parser.add_argument("--timeout", type=float, default=30.0)
    return parser.parse_args()


def main():
    arguments = parse_arguments()
    configuration = adapter.CandidateConfiguration(
        helper_binary=adapter.normalize_wrapper_path(arguments.helper),
        asset_root=adapter.normalize_wrapper_path(arguments.asset_root),
        expected_candidate=arguments.expected_candidate,
        expected_backend=arguments.expected_backend,
        store_root=adapter.normalize_wrapper_path(arguments.store),
        source_manifest=adapter.normalize_wrapper_path(arguments.source_manifest),
        source_sha256=arguments.source_sha256,
        build_identity=arguments.build_identity,
        build_commands=tuple(arguments.build_command),
        operator=arguments.operator,
        agent_role=arguments.agent_role,
        media_fixture_generator=(
            None if arguments.media_fixture_generator is None
            else adapter.normalize_wrapper_path(arguments.media_fixture_generator)
        ),
        timeout_seconds=arguments.timeout,
    )
    _record, path = adapter.run_correctness(arguments.workload, configuration)
    print(path)


if __name__ == "__main__":
    main()
