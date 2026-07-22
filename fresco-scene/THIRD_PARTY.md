# Third-party provenance

The helper and renderer proof use linux-wallpaperengine commit
`b016d7d1fdcf4e5fd2f9c9fa420a8aaa07fee02d`, committed 2026-06-09.

Source: <https://github.com/Almamu/linux-wallpaperengine/tree/b016d7d1fdcf4e5fd2f9c9fa420a8aaa07fee02d>

License: GPL-3.0. The helper and renderer proof as a whole are distributed
under GPL-3.0. `COPYING` contains the license text.

## Package reader

The following paths are copied into `upstream/` with only final-newline
normalization:

- `src/WallpaperEngine/Data/Assets/Package.h`
- `src/WallpaperEngine/Data/Assets/Types.h`
- `src/WallpaperEngine/Data/Parsers/PackageParser.cpp`
- `src/WallpaperEngine/Data/Parsers/PackageParser.h`
- `src/WallpaperEngine/Data/Utils/BinaryReader.cpp`
- `src/WallpaperEngine/Data/Utils/BinaryReader.h`
- `src/WallpaperEngine/Logging/Log.cpp`
- `src/WallpaperEngine/Logging/Log.h`

## Renderer proof

The optional renderer target fetches or accepts a checkout at the exact
linux-wallpaperengine revision above. It compiles a scene-only source cut
directly from that checkout. It does not copy the official Wallpaper Engine
assets or any Workshop package into the repository or build.

The fetch includes only these pinned upstream submodules:

| Component | Revision | License |
| --- | --- | --- |
| glslang-WallpaperEngine | `b775500a153f5ceb0e4b6f366b79c4c57521bb62` | BSD-3-Clause and component notices |
| SPIRV-Cross-WallpaperEngine | `ad4d02220b01c1800e5a4e6671d6d8ca8ab07783` | Apache-2.0 or MIT |
| nlohmann/json | `4424a0fcc1c7fa640b5c87d26776d99150dacd10` | MIT |
| QuickJS-NG | `72ba50f63ee31202f8c18b8d07ab1e1c3486ee6f` | MIT |
| stb | `f0569113c93ad095470c54bf34a17b36646bbbb5` | MIT or public domain |

The target also fetches GLM revision
`0af55ccecd98d4e5a8d1fad7de25ba429d60e863`, corresponding to version 1.0.1,
under the MIT license. It links the installed LZ4 and FreeType libraries. The
linked `lib` sources in LZ4 1.10.0 are BSD-2-Clause. FreeType is available
under the FreeType License or GPL-2.0.

Local compatibility work is explicit:

- `renderer/compat/` replaces the Linux host headers with the fixed Apple
  OpenGL 4.1 API and narrow adapters for text SceneScript, plus no-op sound,
  video, and web paths.
- `renderer/src/TextureCache.cpp` removes the application thumbnail and media
  services from the upstream texture cache.
- `renderer/src/ScriptableObject.cpp` retains property registration and
  explicitly registers GBC Subaru's two scripted animation-rate floats. Other
  dynamic SceneScript values remain deferred.
- `renderer/src/SceneScriptEngine.cpp` embeds QuickJS-NG for persistent text
  layer scripts and the exact GBC-compatible 16-bin band-zero float contract.
- CMake generates a local `CText.cpp` from the pinned source. The patch uses
  Core Text to resolve the macOS system font before FreeType rasterization.
- CMake generates a local `GLSLContext.cpp` from the pinned source. The patch
  emits GLSL 410 without the 420-pack extension and avoids a macOS shutdown
  failure in glslang finalization.
- CMake generates a local `ShaderUnit.cpp` from the pinned source. The patch
  initializes material-backed uniforms to zero when an authored shader omits
  editor-only default metadata; the material constant still replaces that
  value during pass setup.
- CMake generates a local `WallpaperParser.cpp` from the pinned source. The
  patch treats null orthogonal width or height values as the current package
  format's automatic projection mode.
- CMake generates a local `JSON.h` from the pinned source. The patch removes
  `noexcept` from typed optional accessors so current-format type mismatches
  become recoverable package errors instead of terminating the helper.
- CMake generates a local `ObjectParser.cpp` from the pinned source. The patch
  accepts current-format two-component text padding while the upstream model
  still represents padding as one scalar, and preserves numeric-looking text
  placeholders as strings.
- CMake generates a local `CPass.cpp` from the pinned source. The patch binds
  the documented scene-size `g_Screen` uniform used by authored custom
  shaders.
- The proof supplies the upstream project's virtual copy and bloom assets and
  compatibility overloads for the legacy particle fixture.

Distribution of a renderer binary must include the corresponding source for
the pinned upstream revision, its fetched dependencies and notices, these
local patches, and reproducible build instructions. This document records the
engineering boundary; it is not legal advice.

## SDL3 GPU spike

The opt-in SDL3 GPU spike fetches the SDL 3.4.10 release archive:

<https://github.com/libsdl-org/SDL/releases/download/release-3.4.10/SDL3-3.4.10.tar.gz>

The archive SHA-256 is
`12b34280415ec8418c864408b93d008a20a6530687ee613d60bfbd20411f2785`.
SDL is licensed under the zlib license. The fetched `LICENSE.txt` is exactly
884 bytes with SHA-256
`1c040b8271b37e5076359f8fd54240e371114112924d2df81ef87c7d6a1dfdfd`.

`FRESCO_SCENE_BUILD_SDL3_GPU_SPIKE` builds SDL statically for the isolated
spike. It is off by default and has no install rule. A later distributable
binary must carry the SDL license notice and review the static-link packaging
boundary before enabling installation.
