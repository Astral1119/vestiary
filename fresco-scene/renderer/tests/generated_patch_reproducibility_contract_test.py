#!/usr/bin/env python3

import pathlib
import sys


CMAKE_ROOT = pathlib.Path(sys.argv[1])
PUPPET = pathlib.Path(sys.argv[2])

cmake_paths = [CMAKE_ROOT / "CMakeLists.txt", *sorted((CMAKE_ROOT / "cmake").glob("*.cmake"))]
cmake = "\n".join(path.read_text() for path in cmake_paths)
puppet = PUPPET.read_text()

assert cmake.count("file(WRITE") == 1
assert "function(fresco_write_generated output source_variable)" in cmake
assert 'if(NOT DEFINED existing OR NOT existing STREQUAL contents)' in cmake
assert "file(WRITE" not in puppet

assert 'set(puppet_object_parser_source "${object_parser_source}")' in puppet
assert 'set(puppet_wallpaper_parser_source "${wallpaper_parser_source}")' in puppet
assert (
    'fresco_write_generated(\n    "${CMAKE_CURRENT_BINARY_DIR}/generated/ObjectParser.cpp"'
    not in cmake
)
assert (
    'fresco_write_generated(\n    "${CMAKE_CURRENT_BINARY_DIR}/generated/WallpaperParser.cpp"'
    not in cmake
)

print(
    "generated patch reproducibility: content-stable writes and single-stage "
    "parser generation"
)
