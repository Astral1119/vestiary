#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
CONFIG_ROOT=${LIVERY_CONFIG_ROOT:-$HOME/.config}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/livery-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

production_hashes() {
  shasum -a 256 \
    "$CONFIG_ROOT/ghostty/themes/catppuccin-mocha.conf" \
    "$CONFIG_ROOT/sketchybar/colors.lua" \
    "$CONFIG_ROOT/yabai/yabairc" \
    "$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
}

production_hashes > "$TMP/before.sha"

sh -n \
  "$ROOT/liveryctl" \
  "$ROOT/generate-palettes" \
  "$ROOT/generate-themes" \
  "$ROOT/run" \
  "$ROOT/lvry" \
  "$ROOT/../tabard/tabard"
python3 -m py_compile "$ROOT/../fresco/fresco"
plutil -lint "$ROOT/../fresco/HostInfo.plist" >/dev/null
swiftc \
  -warnings-as-errors \
  "$ROOT/../fresco/FrescoHost.swift" \
  -o "$TMP/fresco-host"
swiftc \
  -warnings-as-errors \
  -framework AppKit \
  -framework WebKit \
  -framework AVFoundation \
  "$ROOT/../fresco/Fresco.swift" \
  -o "$TMP/fresco-worker"
"$TMP/fresco-worker" --self-test-agent-counts >/dev/null
swiftc \
  -warnings-as-errors \
  -framework AppKit \
  "$ROOT/../tabard/Tabard.swift" \
  -o "$TMP/tabard"
swiftc \
  -parse-as-library \
  -warnings-as-errors \
  -framework AppKit \
  -framework CoreImage \
  -framework CryptoKit \
  -framework ImageIO \
  -framework UniformTypeIdentifiers \
  -typecheck \
  "$ROOT/ImagePipeline.swift"
swiftc \
  -parse-as-library \
  -warnings-as-errors \
  -framework AppKit \
  -typecheck \
  "$ROOT/WallpaperEngine.swift"
swiftc \
  -parse-as-library \
  -warnings-as-errors \
  -framework AppKit \
  -typecheck \
  "$ROOT/BarLegibility.swift" \
  "$ROOT/LegibilityAnalyzer.swift"
swiftc \
  -parse-as-library \
  -warnings-as-errors \
  -framework AppKit \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers \
  -typecheck \
  "$ROOT/BarLegibility.swift" \
  "$ROOT/LiveryPreview.swift"
jq -e '
  .schemaVersion == 1
    and (.fixtures | length == 6)
    and ([.fixtures[].palettes[]] | all(
      .terminalBackground == .background
        and .terminalForeground == .text
        and .minimumContrast == 3
        and .ghosttyBackgroundOpacity == 0.5
    ))
' "$ROOT/palettes.json" >/dev/null
jq -e '.oneOf | length == 2' "$ROOT/schema/look.schema.json" >/dev/null
jq -e '
  .schemaVersion == 1
    and (.themes | length == 9)
    and ([.themes[].id] | unique | length) == 9
    and ([.themes[].ref] | unique | length) == 9
    and ([.themes[].theme]
      | all(.schemaVersion == 2 and .kind == "semantic-theme"))
    and (.themes[] | select(.id == "violet-hour")
      | .theme.effects.ghosttyBackgroundOpacity == 0.42)
    and (.themes[] | select(.id == "porcelain-day")
      | .theme.variant == "light")
' "$ROOT/themes.json" >/dev/null
jq -e '.properties.schemaVersion.const == 1' \
  "$ROOT/schema/theme-library.schema.json" >/dev/null
jq -e '.properties.schemaVersion.const == 1' \
  "$ROOT/schema/wallpaper-library.schema.json" >/dev/null

themes_before=$(shasum -a 256 "$ROOT/themes.json" | awk '{print $1}')
"$ROOT/generate-themes" >/dev/null
themes_after=$(shasum -a 256 "$ROOT/themes.json" | awk '{print $1}')
[ "$themes_before" = "$themes_after" ]

"$ROOT/liveryctl" themes | while IFS="$(printf '\t')" read -r ref label style tags; do
  [ -n "$ref" ]
  [ -n "$label" ]
  [ -n "$style" ]
  [ -n "$tags" ]
done

library_runtime="$TMP/library-runtime"
LIVERY_RUNTIME_ROOT="$library_runtime" \
  "$ROOT/liveryctl" import-wallpaper \
  "$ROOT/assets/moonlit-ocean.jpg" \
  --name "Imported Moon" \
  --subtitle "dark / local / test" \
  --credit "validation fixture" > "$TMP/imported.json"
jq -e '
  .id == "imported-moon"
    and .name == "Imported Moon"
    and .subtitle == "dark / local / test"
    and .credit == "validation fixture"
    and (.assetDigest | test("^sha256:[0-9a-f]{64}$"))
    and (.palettes | map(.name)) == ["content", "vibrant", "neutral"]
    and (.palettes | all(
      .terminalBackground == .background
        and .terminalForeground == .text
        and .minimumContrast == 3
        and .ghosttyBackgroundOpacity == 0.5
    ))
' "$TMP/imported.json" >/dev/null

LIVERY_RUNTIME_ROOT="$library_runtime" \
  "$ROOT/liveryctl" wallpapers --json > "$TMP/merged-wallpapers.json"
jq -e '
  (.fixtures | length) == 7
    and ([.fixtures[].id] | unique | length) == 7
    and (.fixtures[] | select(.id == "imported-moon")
      | .assetPath | startswith("'"$library_runtime"'/library/assets/"))
' "$TMP/merged-wallpapers.json" >/dev/null

# Reimporting the same bytes returns the existing record without duplicating it.
LIVERY_RUNTIME_ROOT="$library_runtime" \
  "$ROOT/liveryctl" import-wallpaper \
  "$ROOT/assets/moonlit-ocean.jpg" \
  --name "Duplicate Name" > "$TMP/duplicate.json"
[ "$(jq -r '.id' "$TMP/duplicate.json")" = "imported-moon" ]
[ "$(LIVERY_RUNTIME_ROOT="$library_runtime" \
  "$ROOT/liveryctl" wallpapers --json | jq '.fixtures | length')" -eq 7 ]

LIVERY_RUNTIME_ROOT="$library_runtime" \
  "$ROOT/liveryctl" validate wallpaper:imported-moon:content >/dev/null
LIVERY_RUNTIME_ROOT="$library_runtime" \
  "$ROOT/liveryctl" validate theme:violet-hour@imported-moon:balanced >/dev/null

"$ROOT/liveryctl" list | while IFS= read -r profile; do
  "$ROOT/liveryctl" validate "$profile" >/dev/null
done

# Legacy wallpaper-first names remain accepted, but canonical manifests state
# direction explicitly.
"$ROOT/liveryctl" validate neon-city:vibrant >/dev/null

# The live target may intentionally be a generated profile. Compare the
# rendered capture with the stable default runtime rather than with `current`.
if [ -d "$CONFIG_ROOT/livery/default" ]; then
  diff -u \
    "$CONFIG_ROOT/livery/default/ghostty/livery.conf" \
    "$ROOT/build/default/ghostty/livery.conf"
  diff -u \
    "$CONFIG_ROOT/livery/default/sketchybar/colors.lua" \
    "$ROOT/build/default/sketchybar/colors.lua"
  diff -u \
    "$CONFIG_ROOT/livery/default/borders/borders.args" \
    "$ROOT/build/default/borders/borders.args"
fi

candidate="$ROOT/build/wallpaper-neon-city-vibrant/manifest.json"
jq -e --slurpfile baseline "$ROOT/profiles/default.json" '
  def uw: if type == "object" and has("hex") then .hex else . end;
  .schemaVersion == 3
    and .kind == "look-manifest"
    and .locks.signals == true
    and (.signals | walk(uw)) == $baseline[0].signals
    and (.meta.scope == "global")
    and (.ui.onPrimary | uw | test("^#[0-9a-f]{6}$"))
    and (.ui.inverseSurface | uw | test("^#[0-9a-f]{6}$"))
    and (.ui.inverseText | uw | test("^#[0-9a-f]{6}$"))
    and (.ui.inversePrimary | uw | test("^#[0-9a-f]{6}$"))
    and ((.ui.scrim | uw) == "#000000")
    and .coherence.authority == "wallpaper"
    and .coherence.operation == "derive-theme"
    and .coherence.wallpaperScope == "all-managed-spaces"
    and .outputs.wallpaper.digest == .inputs.wallpaper.digest
    and .outputs.wallpaper.derivationDigest != .specDigest
    and .provenance.reproducibility == "replayable"
    and .presentation.barLegibility.textContrastP10 >= 4.5
    and (.presentation.barLegibility.roles | length) == 12
    and (.terminal.base16 | length == 16)
    and (.terminal.ansi | length == 16)
    and .terminal.minimumContrast == 3
    and .terminal.ansi[0] == .terminal.base16[0]
    and .terminal.ansi[1] == .terminal.base16[8]
    and .terminal.ansi[2] == .terminal.base16[11]
    and .terminal.ansi[3] == .terminal.base16[10]
    and .terminal.ansi[4] == .terminal.base16[13]
    and .terminal.ansi[5] == .terminal.base16[14]
    and .terminal.ansi[6] == .terminal.base16[12]
    and .terminal.ansi[7] == .terminal.base16[5]
' "$candidate" >/dev/null

theme_profile="theme:default@warm-dunes:balanced"
theme_stage="$ROOT/build/theme-default-warm-dunes-balanced"
"$ROOT/liveryctl" validate "$theme_profile" >/dev/null
theme_candidate="$theme_stage/manifest.json"
jq -e --slurpfile baseline "$ROOT/profiles/default.json" '
  def uw: if type == "object" and has("hex") then .hex else . end;
  .schemaVersion == 3
    and .kind == "look-manifest"
    and .coherence.authority == "theme"
    and .coherence.operation == "grade-wallpaper"
    and .coherence.constraints.preserveThemeDomains
      == ["ui", "signals", "terminal", "presentation", "effects"]
    and ((.ui | walk(uw) | del(.onPrimary, .outlineVariant, .overlay,
        .inverseSurface, .inverseText, .inversePrimary, .scrim))
      == $baseline[0].ui)
    and (.signals | walk(uw)) == $baseline[0].signals
    and (.terminal | walk(uw)) == $baseline[0].terminal
    and .outputs.theme.digest == .inputs.theme.digest
    and .outputs.wallpaper.digest != .inputs.wallpaper.digest
    and .outputs.wallpaper.derivationDigest != .specDigest
    and .outputs.wallpaper.mediaType == "image/png"
    and .outputs.wallpaper.color.outputSpace == "srgb"
    and .provenance.reproducibility == "reproducible"
    and .evidence.wallpaper.semanticRecoloring == false
    and .presentation.barLegibility.textContrastP10 >= 4.5
' "$theme_candidate" >/dev/null

theme_artifact=$(jq -r '.outputs.wallpaper.artifact' "$theme_candidate")
theme_artifact_digest=$(shasum -a 256 "$theme_stage/$theme_artifact" | awk '{print "sha256:" $1}')
[ "$theme_artifact_digest" = "$(jq -r '.outputs.wallpaper.digest' "$theme_candidate")" ]

# Generated theme references and wallpaper targets must remain independent.
cross_profile="theme:neon-city:vibrant@warm-dunes:balanced"
cross_stage="$ROOT/build/theme-neon-city-vibrant-warm-dunes-balanced"
"$ROOT/liveryctl" validate "$cross_profile" >/dev/null
jq -e '
  .inputs.theme.id == "neon-city:vibrant"
    and .inputs.wallpaper.id == "warm-dunes"
    and .inputs.wallpaper.digest
      == "sha256:f2f6f24677c902035bc726bbc1d7aa50a01cfde34e737f36c5deee030514ce72"
    and .inputs.wallpaper.digest != .outputs.wallpaper.digest
' "$cross_stage/manifest.json" >/dev/null

# Exercise every independent style against varied target imagery.
while read -r theme_ref wallpaper_id; do
  style_profile="theme:$theme_ref@$wallpaper_id:balanced"
  "$ROOT/liveryctl" validate "$style_profile" >/dev/null
  style_slug=$(printf '%s' "$style_profile" | tr ': /@' '----' | tr -cd '[:alnum:]_.-')
  jq -e \
    --arg theme "$theme_ref" \
    --arg wallpaper "$wallpaper_id" '
      .coherence.authority == "theme"
        and .inputs.theme.id == $theme
        and .inputs.wallpaper.id == $wallpaper
        and .outputs.theme.digest == .inputs.theme.digest
        and .outputs.wallpaper.digest != .inputs.wallpaper.digest
        and .presentation.barLegibility.textContrastP10 >= 4.5
    ' "$ROOT/build/$style_slug/manifest.json" >/dev/null
done <<'EOF'
default warm-dunes
violet-hour purple-brutalism
sakura-static neon-city
moss-ledger forest-path
ember-archive warm-dunes
polar-signal blue-alps
graphite-mono moonlit-ocean
acid-relay neon-city
porcelain-day blue-alps
EOF

# Candidate polarity is based on actual luminance, not dark-theme role names.
jq -e '
  .variant == "light"
    and .presentation.barLegibility.polarity == "dark"
    and .presentation.barLegibility.text == .ui.text
    and (.presentation.barLegibility.scrim
      | if type == "object" then .hex else . end) == "#ffffff"
' "$ROOT/build/theme-porcelain-day-blue-alps-balanced/manifest.json" >/dev/null

# A derivation key ignores presentation aliases while the full spec identity
# preserves them.
"$ROOT/liveryctl" validate wallpaper:neon-city:vibrant >/dev/null
"$ROOT/liveryctl" validate neon-city:vibrant >/dev/null
[ "$(jq -r '.outputs.wallpaper.derivationDigest' "$ROOT/build/wallpaper-neon-city-vibrant/manifest.json")" \
  = "$(jq -r '.outputs.wallpaper.derivationDigest' "$ROOT/build/neon-city-vibrant/manifest.json")" ]
[ "$(jq -r '.specDigest' "$ROOT/build/wallpaper-neon-city-vibrant/manifest.json")" \
  != "$(jq -r '.specDigest' "$ROOT/build/neon-city-vibrant/manifest.json")" ]

# Force a byte-for-byte rerender instead of merely hitting the derivative
# cache.
derivation_key=$(jq -r '.outputs.wallpaper.derivationDigest | sub("^sha256:"; "")' "$theme_candidate")
deterministic_before=$(jq -r '.outputs.wallpaper.digest' "$theme_candidate")
rm -f "$ROOT/build/cache/derivatives/$derivation_key.png"
"$ROOT/liveryctl" validate "$theme_profile" >/dev/null
deterministic_after=$(jq -r '.outputs.wallpaper.digest' "$theme_candidate")
[ "$deterministic_before" = "$deterministic_after" ]

for preset in subtle balanced theme-forward; do
  "$ROOT/liveryctl" validate "theme:default@warm-dunes:$preset" >/dev/null
done
subtle_digest=$(jq -r '.outputs.wallpaper.digest' "$ROOT/build/theme-default-warm-dunes-subtle/manifest.json")
balanced_digest=$(jq -r '.outputs.wallpaper.digest' "$ROOT/build/theme-default-warm-dunes-balanced/manifest.json")
forward_digest=$(jq -r '.outputs.wallpaper.digest' "$ROOT/build/theme-default-warm-dunes-theme-forward/manifest.json")
[ "$subtle_digest" != "$balanced_digest" ]
[ "$balanced_digest" != "$forward_digest" ]
[ "$subtle_digest" != "$forward_digest" ]

transform_profile="theme:violet-hour@purple-brutalism:balanced~q8~bayer~grain"
transform_slug=$(printf '%s' "$transform_profile" | tr ': /@~' '-----' | tr -cd '[:alnum:]_.-')
"$ROOT/liveryctl" validate "$transform_profile" >/dev/null
transform_manifest="$ROOT/build/$transform_slug/manifest.json"
jq -e '
  .evidence.wallpaper.recipe == "balanced~q8~bayer~grain"
    and .evidence.wallpaper.operations == [
      "theme.project-image-palette",
      "wallpaper.grade",
      "wallpaper.dither",
      "wallpaper.quantize",
      "wallpaper.grain"
    ]
    and (.pipeline[] | select(.operation == "wallpaper.quantize")
      | .parameters.colors == 8 and .parameters.space == "oklab")
    and (.pipeline[] | select(.operation == "wallpaper.dither")
      | .parameters.algorithm == "bayer")
' "$transform_manifest" >/dev/null

blue_noise_profile="theme:violet-hour@purple-brutalism:subtle~q16~blue-noise~clean"
blue_noise_slug=$(printf '%s' "$blue_noise_profile" | tr ': /@~' '-----' | tr -cd '[:alnum:]_.-')
"$ROOT/liveryctl" validate "$blue_noise_profile" >/dev/null
jq -e '
  [.pipeline[].operation] == [
    "theme.project-image-palette",
    "wallpaper.grade",
    "wallpaper.dither",
    "wallpaper.quantize"
  ]
    and (.pipeline[] | select(.operation == "wallpaper.dither")
      | .parameters.algorithm == "blue-noise")
' "$ROOT/build/$blue_noise_slug/manifest.json" >/dev/null

halftone_profile="theme:acid-relay@neon-city:theme-forward~continuous~none~halftone"
halftone_slug=$(printf '%s' "$halftone_profile" | tr ': /@~' '-----' | tr -cd '[:alnum:]_.-')
"$ROOT/liveryctl" validate "$halftone_profile" >/dev/null
jq -e '
  [.pipeline[].operation] == [
    "theme.project-image-palette",
    "wallpaper.grade",
    "wallpaper.halftone"
  ]
' "$ROOT/build/$halftone_slug/manifest.json" >/dev/null

if "$ROOT/liveryctl" validate \
  "theme:default@warm-dunes:balanced~continuous~bayer~clean" >/dev/null 2>&1
then
  echo "dithering without quantization unexpectedly succeeded" >&2
  exit 1
fi

transform_key=$(jq -r \
  '.outputs.wallpaper.derivationDigest | sub("^sha256:"; "")' \
  "$transform_manifest")
transform_digest_before=$(jq -r '.outputs.wallpaper.digest' "$transform_manifest")
rm -f "$ROOT/build/cache/derivatives/$transform_key.png"
"$ROOT/liveryctl" validate "$transform_profile" >/dev/null
transform_digest_after=$(jq -r '.outputs.wallpaper.digest' "$transform_manifest")
[ "$transform_digest_before" = "$transform_digest_after" ]
[ "$transform_digest_before" \
  != "$(jq -r '.outputs.wallpaper.digest' "$ROOT/build/$blue_noise_slug/manifest.json")" ]

natural_profile="theme:violet-hour@purple-brutalism:balanced~natural~q8~bayer~grain"
natural_slug=$(printf '%s' "$natural_profile" | tr ': /@~' '-----' | tr -cd '[:alnum:]_.-')
"$ROOT/liveryctl" validate "$natural_profile" >/dev/null
[ "$(jq -r '.outputs.wallpaper.derivationDigest' "$transform_manifest")" \
  = "$(jq -r '.outputs.wallpaper.derivationDigest' "$ROOT/build/$natural_slug/manifest.json")" ]

duotone_profile="theme:violet-hour@purple-brutalism:balanced~duotone~continuous~none~clean"
tritone_profile="theme:sakura-static@neon-city:balanced~tritone~continuous~none~clean"
gradient_profile="theme:acid-relay@neon-city:balanced~gradient-map~q8~blue-noise~grain"
for mapping_profile in "$duotone_profile" "$tritone_profile" "$gradient_profile"; do
  "$ROOT/liveryctl" validate "$mapping_profile" >/dev/null
done
duotone_slug=$(printf '%s' "$duotone_profile" | tr ': /@~' '-----' | tr -cd '[:alnum:]_.-')
tritone_slug=$(printf '%s' "$tritone_profile" | tr ': /@~' '-----' | tr -cd '[:alnum:]_.-')
gradient_slug=$(printf '%s' "$gradient_profile" | tr ': /@~' '-----' | tr -cd '[:alnum:]_.-')
jq -e '
  [.pipeline[].operation] == [
    "theme.project-image-palette",
    "wallpaper.grade",
    "wallpaper.map"
  ]
    and (.pipeline[] | select(.operation == "wallpaper.map")
      | .parameters.mode == "duotone"
        and (.parameters.stops | length) == 2
        and .parameters.lightnessStrength < .parameters.strength)
' "$ROOT/build/$duotone_slug/manifest.json" >/dev/null
jq -e '
  (.pipeline[] | select(.operation == "wallpaper.map")
    | .parameters.mode == "tritone" and (.parameters.stops | length) == 3)
' "$ROOT/build/$tritone_slug/manifest.json" >/dev/null
jq -e '
  [.pipeline[].operation] == [
    "theme.project-image-palette",
    "wallpaper.grade",
    "wallpaper.map",
    "wallpaper.dither",
    "wallpaper.quantize",
    "wallpaper.grain"
  ]
    and (.pipeline[] | select(.operation == "wallpaper.map")
      | .parameters.mode == "gradient-map" and (.parameters.stops | length) == 5)
' "$ROOT/build/$gradient_slug/manifest.json" >/dev/null

if "$ROOT/liveryctl" validate \
  "theme:default@warm-dunes:balanced~not-a-map~continuous~none~clean" >/dev/null 2>&1
then
  echo "unknown mapping mode unexpectedly succeeded" >&2
  exit 1
fi

duotone_key=$(jq -r \
  '.outputs.wallpaper.derivationDigest | sub("^sha256:"; "")' \
  "$ROOT/build/$duotone_slug/manifest.json")
duotone_before=$(jq -r '.outputs.wallpaper.digest' "$ROOT/build/$duotone_slug/manifest.json")
rm -f "$ROOT/build/cache/derivatives/$duotone_key.png"
"$ROOT/liveryctl" validate "$duotone_profile" >/dev/null
[ "$duotone_before" \
  = "$(jq -r '.outputs.wallpaper.digest' "$ROOT/build/$duotone_slug/manifest.json")" ]

mkdir -p "$TMP/config/ghostty" "$TMP/config/sketchybar" "$TMP/config/yabai"
printf '%s\n' 'config-file = ?../livery/current/ghostty/livery.conf' > "$TMP/config/ghostty/config"
printf '%s\n' '/current/sketchybar/colors.lua' > "$TMP/config/sketchybar/colors.lua"
printf '%s\n' '.config/livery/current/borders/borders.args' > "$TMP/config/yabai/yabairc"

LIVERY_CONFIG_ROOT="$TMP/config" \
LIVERY_RUNTIME_ROOT="$TMP/runtime" \
LIVERY_SKIP_RELOAD=1 \
  "$ROOT/liveryctl" apply default >/dev/null
LIVERY_CONFIG_ROOT="$TMP/config" \
LIVERY_RUNTIME_ROOT="$TMP/runtime" \
LIVERY_SKIP_RELOAD=1 \
  "$ROOT/liveryctl" apply wallpaper:neon-city:vibrant >/dev/null
[ "$(jq -r '.id' "$TMP/runtime/current/manifest.json")" = "wallpaper:neon-city:vibrant" ]
[ "$(jq -r '.id' "$TMP/runtime/previous/manifest.json")" = "default" ]
[ -f "$TMP/runtime/current/spec.json" ]
[ "$(jq -r '.profile' "$TMP/runtime/state.json")" = "wallpaper:neon-city:vibrant" ]
[ "$(jq -r '.current' "$TMP/runtime/state.json")" = "$(readlink "$TMP/runtime/current")" ]
[ "$(jq -r '.previous' "$TMP/runtime/state.json")" = "$(readlink "$TMP/runtime/previous")" ]
[ "$(jq -r '.scope' "$TMP/runtime/state.json")" = "look" ]
[ "$(jq -r '.wallpaperCurrent' "$TMP/runtime/state.json")" = "$(readlink "$TMP/runtime/wallpaper/current")" ]
[ "$(jq -r '.wallpaperPrevious' "$TMP/runtime/state.json")" = "$(readlink "$TMP/runtime/wallpaper/previous")" ]
previous_before_reapply=$(readlink "$TMP/runtime/previous")
wallpaper_previous_before_reapply=$(readlink "$TMP/runtime/wallpaper/previous")
LIVERY_CONFIG_ROOT="$TMP/config" \
LIVERY_RUNTIME_ROOT="$TMP/runtime" \
LIVERY_SKIP_RELOAD=1 \
  "$ROOT/liveryctl" apply wallpaper:neon-city:vibrant >/dev/null
[ "$(readlink "$TMP/runtime/previous")" = "$previous_before_reapply" ]
[ "$(readlink "$TMP/runtime/wallpaper/previous")" = "$wallpaper_previous_before_reapply" ]
LIVERY_CONFIG_ROOT="$TMP/config" \
LIVERY_RUNTIME_ROOT="$TMP/runtime" \
LIVERY_SKIP_RELOAD=1 \
  "$ROOT/liveryctl" apply "$theme_profile" >/dev/null
[ "$(jq -r '.coherence.authority' "$TMP/runtime/current/manifest.json")" = "theme" ]
runtime_artifact=$(jq -r '.outputs.wallpaper.artifact' "$TMP/runtime/current/manifest.json")
[ -f "$TMP/runtime/current/$runtime_artifact" ]
LIVERY_CONFIG_ROOT="$TMP/config" \
LIVERY_RUNTIME_ROOT="$TMP/runtime" \
LIVERY_SKIP_RELOAD=1 \
  "$ROOT/liveryctl" rollback >/dev/null
[ "$(jq -r '.id' "$TMP/runtime/current/manifest.json")" = "wallpaper:neon-city:vibrant" ]
[ "$(jq -r '.id' "$TMP/runtime/previous/manifest.json")" = "$theme_profile" ]
[ "$(jq -r '.profile' "$TMP/runtime/state.json")" = "wallpaper:neon-city:vibrant" ]
[ "$(jq -r '.current' "$TMP/runtime/state.json")" = "$(readlink "$TMP/runtime/current")" ]
[ "$(jq -r '.previous' "$TMP/runtime/state.json")" = "$(readlink "$TMP/runtime/previous")" ]
[ "$(jq -r '.scope' "$TMP/runtime/state.json")" = "look" ]
[ "$(jq -r '.wallpaperCurrent' "$TMP/runtime/state.json")" = "$(readlink "$TMP/runtime/wallpaper/current")" ]
[ "$(jq -r '.wallpaperPrevious' "$TMP/runtime/state.json")" = "$(readlink "$TMP/runtime/wallpaper/previous")" ]

# A file pin survives Look apply and rollback as orthogonal global state.
lock_image="$(CDPATH='' cd -- "$ROOT/assets" && pwd)/moonlit-ocean.jpg"
LIVERY_CONFIG_ROOT="$TMP/config" \
LIVERY_RUNTIME_ROOT="$TMP/runtime" \
LIVERY_SKIP_RELOAD=1 \
  "$ROOT/liveryctl" lock "$lock_image" >/dev/null
[ "$(jq -r '.source' "$TMP/runtime/lock.json")" = "file" ]
pinned_image=$(jq -r '.image' "$TMP/runtime/lock.json")
[ "$pinned_image" = "$lock_image" ]
LIVERY_CONFIG_ROOT="$TMP/config" \
LIVERY_RUNTIME_ROOT="$TMP/runtime" \
LIVERY_SKIP_RELOAD=1 \
  "$ROOT/liveryctl" apply "$theme_profile" >/dev/null
[ "$(jq -r '.source' "$TMP/runtime/lock.json")" = "file" ]
[ "$(jq -r '.image' "$TMP/runtime/lock.json")" = "$pinned_image" ]

# Lock-only application renders the exact selected Look wallpaper and caches it
# independently from the mutable staging directory.
LIVERY_CONFIG_ROOT="$TMP/config" \
LIVERY_RUNTIME_ROOT="$TMP/runtime" \
LIVERY_SKIP_RELOAD=1 \
  "$ROOT/liveryctl" lock "look:$theme_profile" >/dev/null
[ "$(jq -r '.source' "$TMP/runtime/lock.json")" = "look" ]
[ "$(jq -r '.selection' "$TMP/runtime/lock.json")" = "$theme_profile" ]
look_lock_image=$(jq -r '.image' "$TMP/runtime/lock.json")
case "$look_lock_image" in
  "$TMP/runtime/lock/looks/"*) ;;
  *) echo "Look lock image was not cached under the runtime" >&2; exit 1 ;;
esac
[ -f "$look_lock_image" ]
[ "$(shasum -a 256 "$look_lock_image" | awk '{print $1}')" \
  = "$(jq -r '.outputs.wallpaper.digest | sub("^sha256:"; "")' "$theme_candidate")" ]
LIVERY_CONFIG_ROOT="$TMP/config" \
LIVERY_RUNTIME_ROOT="$TMP/runtime" \
LIVERY_SKIP_RELOAD=1 \
  "$ROOT/liveryctl" rollback >/dev/null
[ "$(jq -r '.source' "$TMP/runtime/lock.json")" = "look" ]
[ "$(jq -r '.image' "$TMP/runtime/lock.json")" = "$look_lock_image" ]

# Scene selection retains its library identity. Video scenes are reduced to a
# cached, content-addressed representative still for the macOS wallpaper store.
scene_root="$TMP/scenes"
mkdir -p "$scene_root"
if command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -loglevel error -y -loop 1 -i "$lock_image" \
    -t 1 -r 30 -vf 'scale=64:-2' -pix_fmt yuv420p \
    "$scene_root/test-scene.mp4"
  scene_name=test-scene
else
  cp "$lock_image" "$scene_root/test-scene.jpg"
  scene_name=test-scene
fi
LIVERY_CONFIG_ROOT="$TMP/config" \
LIVERY_RUNTIME_ROOT="$TMP/runtime" \
LIVERY_SCENE_ROOT="$scene_root" \
LIVERY_SKIP_RELOAD=1 \
  "$ROOT/liveryctl" lock "scene:$scene_name" >/dev/null
[ "$(jq -r '.source' "$TMP/runtime/lock.json")" = "scene" ]
[ "$(jq -r '.selection' "$TMP/runtime/lock.json")" = "scene:$scene_name" ]
[ -f "$(jq -r '.image' "$TMP/runtime/lock.json")" ]
if command -v ffmpeg >/dev/null 2>&1; then
  case "$(jq -r '.image' "$TMP/runtime/lock.json")" in
    "$TMP/runtime/lock/scenes/"*.png) ;;
    *) echo "scene lock image was not cached under the runtime" >&2; exit 1 ;;
  esac
fi

# Theme mode follows the active profile and off removes lock-specific state.
LIVERY_CONFIG_ROOT="$TMP/config" \
LIVERY_RUNTIME_ROOT="$TMP/runtime" \
LIVERY_SKIP_RELOAD=1 \
  "$ROOT/liveryctl" lock theme >/dev/null
[ "$(jq -r '.source' "$TMP/runtime/lock.json")" = "theme" ]
theme_lock_artifact=$(jq -r '.outputs.wallpaper.artifact' "$TMP/runtime/current/manifest.json")
[ "$(jq -r '.image' "$TMP/runtime/lock.json")" \
  = "$TMP/runtime/$(readlink "$TMP/runtime/current")/$theme_lock_artifact" ]
LIVERY_CONFIG_ROOT="$TMP/config" \
LIVERY_RUNTIME_ROOT="$TMP/runtime" \
LIVERY_SKIP_RELOAD=1 \
  "$ROOT/liveryctl" lock off >/dev/null
[ ! -e "$TMP/runtime/lock.json" ]

# Repose rotations are ordered catalog membership, not current-scene
# selection. Missing state migrates to every scene; membership writes preserve
# order, remove duplicates, and reconcile an excluded current scene.
repose_home="$TMP/repose-home"
mkdir -p "$repose_home/.config/fresco/scenes" \
  "$repose_home/.config/fresco/bin"
: > "$repose_home/.config/fresco/scenes/alpha.mp4"
: > "$repose_home/.config/fresco/scenes/beta.mp4"
: > "$repose_home/.config/fresco/bin/fresco"
HOME="$repose_home" "$ROOT/../fresco/fresco" repose-state \
  > "$TMP/repose-default.json"
jq -e '
  .scenePool == ["desktop", "alpha.mp4", "beta.mp4"]
    and .viz == "strings"
' \
  "$TMP/repose-default.json" >/dev/null
HOME="$repose_home" "$ROOT/../fresco/fresco" \
  repose-pool beta.mp4 alpha.mp4 beta.mp4 >/dev/null
HOME="$repose_home" "$ROOT/../fresco/fresco" \
  repose-viz spectrum >/dev/null
jq -e '
  .scenePool == ["beta.mp4", "alpha.mp4"]
    and (.scene | endswith("/scenes/beta.mp4"))
    and .viz == "spectrum"
' "$repose_home/.config/fresco/repose.json" >/dev/null

production_hashes > "$TMP/after.sha"
diff -u "$TMP/before.sha" "$TMP/after.sha"

echo "livery dry-run validation passed"
