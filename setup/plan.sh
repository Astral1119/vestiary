#!/bin/sh

setup_dependency_rows() {
  cat <<'EOF'
jq	required	required for setup planning and Livery
swiftc	required	builds the native Livery and Fresco helpers
cargo	optional	Matugen fallback build outside Apple silicon
ffmpeg	optional	scene lock images and video frame extraction
cava	optional	audio-reactive wallpapers
media-control	optional	now-playing data
steamcmd	optional	Wallpaper Engine Workshop downloads
EOF
}

setup_command_found() {
  command -v "$1" >/dev/null 2>&1
}

setup_discovered_adapters() {
  if [ -n "${LIVERY_ADAPTERS_ROOT:-}" ]; then
    setup_adapter_path=$LIVERY_ADAPTERS_ROOT
  else
    setup_config_root=${LIVERY_CONFIG_ROOT:-"$HOME/.config"}
    setup_user_adapters=${LIVERY_USER_ADAPTERS_ROOT:-"$setup_config_root/vestiary/adapters.d"}
    setup_adapter_path=${LIVERY_ADAPTER_PATH:-"$REPO_ROOT/adapters:$setup_user_adapters"}
  fi
  setup_seen='|'
  setup_old_ifs=$IFS
  IFS=:
  for directory in $setup_adapter_path; do
    IFS=$setup_old_ifs
    [ -d "$directory" ] || { IFS=:; continue; }
    for candidate in "$directory"/*; do
      [ -f "$candidate" ] && [ -x "$candidate" ] || continue
      id=$(basename "$candidate")
      case $setup_seen in *"|$id|"*) continue ;; esac
      setup_seen="$setup_seen$id|"
      printf '%s\t%s\t%s\n' "$id" "$candidate" "$directory/$id.target.json"
    done
    IFS=:
  done
  IFS=$setup_old_ifs
}

setup_adapter_detected() {
  metadata=$1
  [ -r "$metadata" ] || return 1
  command_name=$(jq -r '.detect.command // empty' "$metadata")
  application=$(jq -r '.detect.application // empty' "$metadata")
  if [ -z "$command_name" ] && [ -z "$application" ]; then
    return 0
  fi
  if [ -n "$command_name" ] && setup_command_found "$command_name"; then
    return 0
  fi
  [ -n "$application" ] \
    && { [ -d "/Applications/$application" ] || [ -d "$HOME/Applications/$application" ]; }
}

setup_targets_status() {
  targets_config=$1
  known_adapters=$2
  [ -e "$targets_config" ] || { echo absent; return; }
  if jq -e --argjson known "$known_adapters" '
    . as $root
    | (if $root | has("enabled") then $root.enabled else [] end) as $enabled
    | (if $root | has("disabled") then $root.disabled else [] end) as $disabled
    | type == "object"
      and ($enabled | type == "array" and all(type == "string"))
      and ($disabled | type == "array" and all(type == "string"))
      and (($enabled | unique | length) == ($enabled | length))
      and (($disabled | unique | length) == ($disabled | length))
      and (($enabled - $disabled | length) == ($enabled | length))
      and (all($enabled[], $disabled[]; $known | index(.) != null))
  ' "$targets_config" >/dev/null 2>&1; then
    echo present
  else
    echo invalid
  fi
}

setup_receipt_status() {
  receipt_path=$1
  [ -e "$receipt_path" ] || { echo absent; return; }
  if jq -e '.schemaVersion == 1 and (.resources | type == "array")' \
    "$receipt_path" >/dev/null 2>&1; then
    echo present
  else
    echo invalid
  fi
}

setup_adapter_selected() {
  id=$1
  targets_config=$2
  livery_runtime=$3
  targets_status=$4
  [ "$id" = css ] && return 0
  if [ "$targets_status" = present ]; then
    jq -e --arg id "$id" '
      ((has("enabled") | not) or (.enabled | index($id) != null))
        and ((.disabled // []) | index($id) == null)
    ' "$targets_config" >/dev/null 2>&1
    return
  fi
  if [ "$targets_status" = absent ] && [ -e "$livery_runtime" ]; then
    return 0
  fi
  return 1
}

emit_setup_plan() {
  targets_config=$1
  livery_runtime=$2
  receipt_path=$3

  command -v jq >/dev/null 2>&1 || {
    echo "install --plan requires jq" >&2
    return 1
  }

  dependency_records=$(mktemp "${TMPDIR:-/tmp}/vestiary-plan-dependencies.XXXXXX")
  integration_records=$(mktemp "${TMPDIR:-/tmp}/vestiary-plan-integrations.XXXXXX")
  selected_adapters=$(mktemp "${TMPDIR:-/tmp}/vestiary-plan-selected.XXXXXX")
  known_adapters=$(setup_discovered_adapters | cut -f1 \
    | jq -Rsc 'split("\n") | map(select(length > 0))')
  css_available=false
  printf '%s' "$known_adapters" | jq -e 'index("css") != null' >/dev/null \
    && css_available=true
  targets_status=$(setup_targets_status "$targets_config" "$known_adapters")
  receipt_status=$(setup_receipt_status "$receipt_path")

  while IFS="$(printf '\t')" read -r id need consequence; do
    [ -n "$id" ] || continue
    found=false
    setup_command_found "$id" && found=true
    jq -cn --arg id "$id" --arg need "$need" --arg consequence "$consequence" \
      --argjson found "$found" \
      '{id:$id, need:$need, found:$found, consequence:$consequence}' \
      >> "$dependency_records"
  done <<EOF
$(setup_dependency_rows)
EOF

  while IFS="$(printf '\t')" read -r id adapter_path metadata; do
    [ -n "$id" ] || continue
    if [ -r "$metadata" ]; then
      metadata_json=$(jq -c . "$metadata")
    else
      metadata_json=$(jq -cn --arg id "$id" \
        '{schemaVersion:1,id:$id,displayName:$id,kind:"adapter",consumes:[],detect:{}}')
    fi
    detected=false
    setup_adapter_detected "$metadata" && detected=true
    selected=false
    if setup_adapter_selected "$id" "$targets_config" "$livery_runtime" "$targets_status"; then
      selected=true
      printf '%s\n' "$id" >> "$selected_adapters"
    fi
    jq -cn --argjson metadata "$metadata_json" --arg adapterPath "$adapter_path" \
      --argjson detected "$detected" --argjson selected "$selected" '
      {id:$metadata.id, displayName:$metadata.displayName, kind:"adapter",
       path:$adapterPath,
       detected:$detected, selected:$selected,
       consent:(if $metadata.id == "css" then "automatic" else "explicit" end),
       consumes:($metadata.consumes // [])}
    ' >> "$integration_records"
  done <<EOF
$(setup_discovered_adapters)
EOF

  vscode_detected=false
  vscode_installed=false
  vscode_managed=false
  setup_command_found code && vscode_detected=true
  if [ "$vscode_detected" = true ] \
    && code --list-extensions 2>/dev/null | grep -Fxiq vestiary.vestiary-vscode; then
    vscode_installed=true
  fi
  if [ "$receipt_status" = present ] && jq -e '
    .resources[] | select(.kind == "editor-extension"
      and .host == "code" and .id == "vestiary.vestiary-vscode")
  ' "$receipt_path" >/dev/null 2>&1; then
    vscode_managed=true
  fi
  vscode_ready=true
  vscode_blocked_reason=
  if [ "$vscode_managed" = true ] && { [ "$vscode_detected" != true ] \
    || { [ "$vscode_installed" != true ] && ! setup_command_found npm; }; }; then
    vscode_ready=false
    if [ "$vscode_detected" != true ]; then
      vscode_blocked_reason=host-command-unavailable
    else
      vscode_blocked_reason=extension-absent-and-npm-unavailable
    fi
  fi
  jq -cn --argjson detected "$vscode_detected" --argjson installed "$vscode_installed" \
    --argjson managed "$vscode_managed" --argjson ready "$vscode_ready" \
    --arg blockedReason "$vscode_blocked_reason" '
    {id:"vscode", displayName:"Visual Studio Code", kind:"editor-extension",
     detected:$detected, installed:$installed, managed:$managed,
     selected:$managed, ready:$ready,
     blockedReason:(if $blockedReason == "" then null else $blockedReason end),
     consent:"explicit"}
  ' >> "$integration_records"

  os_name=$(uname -s 2>/dev/null || echo unknown)
  architecture=${VESTIARY_TEST_ARCH:-$(uname -m 2>/dev/null || echo unknown)}
  os_version=$(sw_vers -productVersion 2>/dev/null || echo unknown)
  matugen=${VESTIARY_MATUGEN:-"$REPO_ROOT/livery/tools/bin/matugen"}
  matugen_installed=false
  matugen_operation=download
  matugen_ready=true
  if [ -x "$matugen" ]; then
    matugen_installed=true
    matugen_operation=none
  elif [ "$architecture" != arm64 ]; then
    matugen_operation=cargo-build
    setup_command_found cargo || matugen_ready=false
  fi
  selection_basis=current
  [ "$targets_status" = absent ] && selection_basis=fresh-default
  [ "$targets_status" = absent ] && [ -e "$livery_runtime" ] && selection_basis=legacy-default
  [ "$targets_status" = invalid ] && selection_basis=repair-invalid-targets
  targets_ready=true
  [ "$targets_status" = invalid ] && targets_ready=false
  receipt_ready=true
  [ "$receipt_status" = invalid ] && receipt_ready=false

  jq -n \
    --arg os "$os_name" --arg osVersion "$os_version" --arg architecture "$architecture" \
    --arg targetsConfig "$targets_config" --arg targetsStatus "$targets_status" \
    --arg receipt "$receipt_path" --arg receiptStatus "$receipt_status" \
    --arg selectionBasis "$selection_basis" \
    --argjson targetsReady "$targets_ready" --argjson receiptReady "$receipt_ready" \
    --argjson cssAvailable "$css_available" \
    --argjson vscodeReady "$vscode_ready" --argjson matugenReady "$matugen_ready" \
    --argjson matugenInstalled "$matugen_installed" --arg matugenOperation "$matugen_operation" \
    --arg matugenPath "$matugen" \
    --slurpfile prerequisites "$dependency_records" \
    --slurpfile integrations "$integration_records" \
    --rawfile selectedAdapters "$selected_adapters" '
    {schemaVersion:1, kind:"vestiary-setup-plan",
     system:{os:$os, version:$osVersion, architecture:$architecture,
       compatible:($os == "Darwin")},
     prerequisites:$prerequisites,
     readyToApply:(($os == "Darwin")
       and all($prerequisites[]; .need != "required" or .found)
       and $targetsReady and $receiptReady and $vscodeReady and $matugenReady
       and $cssAvailable),
     integrations:$integrations,
     permissions:[
       {id:"screen-audio-recording", requiredFor:["audio-reactive-wallpapers"],
        managed:false, status:"unknown"},
       {id:"yabai-setup", requiredFor:["jankyborders-loader"],
        managed:false, status:"external"}],
     state:{targetsConfig:$targetsConfig, targetsStatus:$targetsStatus,
       receipt:$receipt, receiptStatus:$receiptStatus,
       selectionBasis:$selectionBasis, cssAvailable:$cssAvailable},
     selection:{schemaVersion:1, kind:"vestiary-setup-selection",
       adapters:($selectedAdapters | split("\n") | map(select(length > 0))),
       wireLoaders:false,
       integrations:{vscode:([$integrations[] | select(.id == "vscode")][0].selected)}},
     actions:[
       {id:"matugen", operation:$matugenOperation, path:$matugenPath,
        installed:$matugenInstalled, ready:$matugenReady,
        network:($matugenOperation == "download")},
       {id:"targets", operation:"write-selection", path:$targetsConfig},
       {id:"shims", operation:"install-or-update", receiptOwned:true},
       {id:"loaders", operation:"wire-selected", selected:false, receiptOwned:true},
       {id:"vscode", operation:"install-or-manage",
        selected:([$integrations[] | select(.id == "vscode")][0].selected),
        receiptOwned:true}]}
  '

  rm -f "$dependency_records" "$integration_records" "$selected_adapters"
}

apply_setup_selection() {
  selection_path=$1
  targets_config=$2
  [ "$(uname -s 2>/dev/null || echo unknown)" = Darwin ] || {
    echo "install: Vestiary setup requires macOS" >&2
    return 1
  }
  [ -r "$selection_path" ] || {
    echo "install: selection is unreadable: $selection_path" >&2
    return 1
  }

  if jq -e '.kind == "vestiary-setup-plan" and (.readyToApply != true)' \
    "$selection_path" >/dev/null 2>&1; then
    echo "install: setup plan is not ready to apply" >&2
    return 1
  fi

  selection=$(jq -c '
    if .kind == "vestiary-setup-plan" then .selection else . end
  ' "$selection_path") || return 1
  printf '%s' "$selection" | jq -e '
    .schemaVersion == 1 and .kind == "vestiary-setup-selection"
      and (.adapters | type == "array" and length > 0
        and all(type == "string") and (index("css") != null)
        and ((unique | length) == length))
      and (.wireLoaders | type == "boolean")
      and (.integrations | type == "object")
      and (.integrations.vscode | type == "boolean")
  ' >/dev/null || {
    echo "install: invalid setup selection: $selection_path" >&2
    return 1
  }

  known_adapters=$(setup_discovered_adapters | cut -f1)
  requested_adapters=$(printf '%s' "$selection" | jq -r '.adapters[]')
  for requested in $requested_adapters; do
    printf '%s\n' "$known_adapters" | grep -Fxq "$requested" || {
      echo "install: unknown adapter in setup selection: $requested" >&2
      return 1
    }
  done

  if [ "$(printf '%s' "$selection" | jq -r '.integrations.vscode')" = true ]; then
    command -v code >/dev/null 2>&1 || {
      echo "install: selected VS Code integration but 'code' is unavailable" >&2
      return 1
    }
    if ! code --list-extensions 2>/dev/null | grep -Fxiq vestiary.vestiary-vscode \
      && ! command -v npm >/dev/null 2>&1; then
      echo "install: npm is required to install the selected VS Code integration" >&2
      return 1
    fi
  fi

  matugen=${VESTIARY_MATUGEN:-"$REPO_ROOT/livery/tools/bin/matugen"}
  if [ ! -x "$matugen" ]; then
    apply_architecture=${VESTIARY_TEST_ARCH:-$(uname -m 2>/dev/null || echo unknown)}
    if [ "$apply_architecture" != arm64 ] \
      && ! command -v cargo >/dev/null 2>&1; then
      echo "install: Cargo is required to acquire Matugen on this architecture" >&2
      return 1
    fi
    echo "matugen: acquiring pinned release before setup apply" >&2
    "$REPO_ROOT/livery/tools/fetch-matugen" || {
      echo "install: Matugen acquisition failed before setup apply" >&2
      return 1
    }
    [ -x "$matugen" ] || {
      echo "install: Matugen acquisition did not produce $matugen" >&2
      return 1
    }
  fi

  receipt_init
  mkdir -p "$(dirname "$targets_config")"
  targets_tmp=$(mktemp "${TMPDIR:-/tmp}/vestiary-targets.XXXXXX")
  printf '%s' "$selection" | jq --argjson known "$(printf '%s\n' "$known_adapters" | jq -Rsc 'split("\n") | map(select(length > 0))')" '
    {schemaVersion:1, enabled:.adapters, disabled:($known - .adapters)}
  ' > "$targets_tmp"
  mv "$targets_tmp" "$targets_config"

  if [ "$(printf '%s' "$selection" | jq -r '.wireLoaders')" = true ]; then
    WIRE=yes
  else
    WIRE=no
  fi
  if [ "$(printf '%s' "$selection" | jq -r '.integrations.vscode')" = true ]; then
    VSCODE=yes
  else
    VSCODE=no
  fi
  export WIRE VSCODE
}
