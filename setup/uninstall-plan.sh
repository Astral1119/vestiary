#!/bin/sh

uninstall_plan_action() {
  resource=$1
  operation=$2
  outcome=$3
  reason=$4
  jq -cn --argjson resource "$resource" --arg operation "$operation" \
    --arg outcome "$outcome" --arg reason "$reason" \
    '{resource:$resource, operation:$operation, outcome:$outcome,
      reason:(if $reason == "" then null else $reason end)}'
}

plan_purge_path() {
  target=$1
  while [ "${target%/}" != "$target" ]; do target=${target%/}; done
  case $target in
    ''|/*/../*|*/..|/*/./*|*/.|'.'|'..'|"$HOME"|"$HOME/.config"|"$REPO_ROOT")
      return 1 ;;
    /*) ;;
    *) return 1 ;;
  esac
  target_parent=$(dirname "$target")
  [ -d "$target_parent" ] || return 0
  canonical_target=$(cd "$target_parent" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$target")")
  plan_tmp_root=${TMPDIR:-/tmp}
  while [ "${plan_tmp_root%/}" != "$plan_tmp_root" ]; do
    plan_tmp_root=${plan_tmp_root%/}
  done
  [ -d "$plan_tmp_root" ] && plan_tmp_root=$(cd "$plan_tmp_root" && pwd -P)
  case $plan_tmp_root in
    ''|'/'|"$HOME"|"$REPO_ROOT") plan_tmp_root=/__vestiary_no_temp_root__ ;;
  esac
  case "$HOME/" in "$plan_tmp_root/"*) plan_tmp_root=/__vestiary_no_temp_root__ ;; esac
  case "$REPO_ROOT/" in "$plan_tmp_root/"*) plan_tmp_root=/__vestiary_no_temp_root__ ;; esac
  case $canonical_target in
    "$HOME/.config/"*|"$plan_tmp_root/"*) ;;
    *) return 1 ;;
  esac
  case "$HOME/" in "$canonical_target/"*) return 1 ;; esac
  case "$REPO_ROOT/" in "$canonical_target/"*) return 1 ;; esac
  return 0
}

emit_uninstall_plan() {
  keep_integrations=$1
  purge=$2
  receipt_path=$3
  config_root=$4

  command -v jq >/dev/null 2>&1 || {
    echo "uninstall --plan requires jq" >&2
    return 1
  }
  resource_actions=$(mktemp "${TMPDIR:-/tmp}/vestiary-uninstall-resources.XXXXXX")
  runtime_actions=$(mktemp "${TMPDIR:-/tmp}/vestiary-uninstall-runtime.XXXXXX")
  receipt_status=absent
  [ -e "$receipt_path" ] && receipt_status=invalid

  if [ -r "$receipt_path" ] && jq -e '
    .schemaVersion == 1 and (.resources | type == "array")
  ' "$receipt_path" >/dev/null 2>&1; then
    receipt_status=present
    while IFS= read -r resource; do
      kind=$(printf '%s' "$resource" | jq -r '.kind')
      case $kind in
        shim)
          path=$(printf '%s' "$resource" | jq -r '.path')
          expected=$(printf '%s' "$resource" | jq -r '.digest')
          if [ ! -e "$path" ] && [ ! -L "$path" ]; then
            uninstall_plan_action "$resource" none unchanged already-absent
          elif [ -f "$path" ] && [ "$(file_digest "$path")" = "$expected" ]; then
            uninstall_plan_action "$resource" remove planned ''
          else
            uninstall_plan_action "$resource" preserve preserved modified
          fi
          ;;
        loader-line)
          if [ "$keep_integrations" = yes ]; then
            uninstall_plan_action "$resource" preserve preserved keep-integrations
          else
            path=$(printf '%s' "$resource" | jq -r '.path')
            line=$(printf '%s' "$resource" | jq -r '.line')
            if [ -f "$path" ] && grep -Fxq "$line" "$path"; then
              uninstall_plan_action "$resource" remove-one-line planned ''
            else
              uninstall_plan_action "$resource" none unchanged already-absent
            fi
          fi
          ;;
        managed-file)
          if [ "$keep_integrations" = yes ]; then
            uninstall_plan_action "$resource" preserve preserved keep-integrations
          else
            path=$(printf '%s' "$resource" | jq -r '.path')
            expected=$(printf '%s' "$resource" | jq -r '.digest')
            backup=$(printf '%s' "$resource" | jq -r '.backup // empty')
            backup_digest=$(printf '%s' "$resource" | jq -r '.backupDigest // empty')
            if [ ! -e "$path" ]; then
              uninstall_plan_action "$resource" none unchanged already-absent
            elif [ ! -f "$path" ] || [ "$(file_digest "$path")" != "$expected" ]; then
              uninstall_plan_action "$resource" preserve preserved modified
            elif [ -z "$backup" ]; then
              uninstall_plan_action "$resource" remove planned ''
            elif [ -f "$backup" ] && [ "$(file_digest "$backup")" = "$backup_digest" ]; then
              uninstall_plan_action "$resource" restore planned verified-backup
            else
              uninstall_plan_action "$resource" preserve blocked backup-unavailable
            fi
          fi
          ;;
        editor-extension)
          if [ "$keep_integrations" = yes ]; then
            uninstall_plan_action "$resource" preserve preserved keep-integrations
          else
            host=$(printf '%s' "$resource" | jq -r '.host')
            extension=$(printf '%s' "$resource" | jq -r '.id')
            if [ "$extension" = vestiary.vestiary-vscode ]; then
              vscode_state=${VESTIARY_VSCODE_STATE:-"$config_root/integrations/vscode.json"}
              if [ ! -r "$vscode_state" ] || ! jq -e '.schemaVersion == 1
                  and ((.attached == false) or (.ownsColors == false))' \
                  "$vscode_state" >/dev/null 2>&1; then
                uninstall_plan_action "$resource" preserve blocked colors-attached-or-unknown
              elif ! command -v "$host" >/dev/null 2>&1; then
                uninstall_plan_action "$resource" preserve blocked host-command-unavailable
              elif ! "$host" --list-extensions 2>/dev/null | grep -Fxiq "$extension"; then
                uninstall_plan_action "$resource" none unchanged already-absent
              else
                uninstall_plan_action "$resource" uninstall planned detached
              fi
            elif ! command -v "$host" >/dev/null 2>&1; then
              uninstall_plan_action "$resource" preserve blocked host-command-unavailable
            elif ! "$host" --list-extensions 2>/dev/null | grep -Fxiq "$extension"; then
              uninstall_plan_action "$resource" none unchanged already-absent
            else
              uninstall_plan_action "$resource" uninstall planned ''
            fi
          fi
          ;;
        *) uninstall_plan_action "$resource" preserve blocked unknown-resource-kind ;;
      esac >> "$resource_actions"
    done <<EOF
$(jq -c '.resources[]' "$receipt_path")
EOF
  fi

  if [ "$purge" = yes ]; then
    for runtime in \
      "livery:${LIVERY_RUNTIME_ROOT:-${LIVERY_CONFIG_ROOT:-$HOME/.config}/livery}" \
      "fresco:${FRESCO_STATE_DIR:-$HOME/.config/fresco}" \
      "fresco-compat:${FRESCO_COMPAT_DIR:-$HOME/.config/wallpaper-runtime}" \
      "vestiary:$config_root"; do
      id=${runtime%%:*}
      path=${runtime#*:}
      if [ "$id" = vestiary ] && [ "$receipt_status" = invalid ]; then
        jq -cn --arg id "$id" --arg path "$path" \
          '{id:$id,path:$path,operation:"preserve",outcome:"blocked",
            reason:"invalid-install-receipt"}'
      elif [ "$id" = vestiary ] && jq -se '
        any(.[]; .outcome == "blocked" or .outcome == "preserved")
      ' "$resource_actions" >/dev/null 2>&1; then
        jq -cn --arg id "$id" --arg path "$path" \
          '{id:$id,path:$path,operation:"preserve",outcome:"blocked",
            reason:"unresolved-receipt-resources"}'
      elif plan_purge_path "$path"; then
        jq -cn --arg id "$id" --arg path "$path" \
          '{id:$id,path:$path,operation:"remove-recursive",outcome:"planned"}'
      else
        jq -cn --arg id "$id" --arg path "$path" \
          '{id:$id,path:$path,operation:"preserve",outcome:"blocked",
            reason:"unsafe-purge-target"}'
      fi
    done > "$runtime_actions"
  fi

  fresco_app=${VESTIARY_FRESCO_APP:-"$HOME/Applications/Fresco.app"}
  fresco_operation=none
  fresco_outcome=unchanged
  if [ -d "$fresco_app" ]; then
    fresco_operation=preserve
    fresco_outcome=preserved
    bundle_id=$(plutil -extract CFBundleIdentifier raw -o - \
      "$fresco_app/Contents/Info.plist" 2>/dev/null || true)
    if [ "$bundle_id" = local.vestiary.fresco ] \
      && codesign --verify --strict "$fresco_app" >/dev/null 2>&1; then
      fresco_operation=remove
      fresco_outcome=planned
    fi
  fi

  jq -n --arg receipt "$receipt_path" --argjson keepIntegrations \
    "$( [ "$keep_integrations" = yes ] && echo true || echo false )" \
    --argjson purge "$( [ "$purge" = yes ] && echo true || echo false )" \
    --slurpfile resources "$resource_actions" --slurpfile runtime "$runtime_actions" \
    --arg frescoApp "$fresco_app" --arg frescoOperation "$fresco_operation" \
    --arg frescoOutcome "$fresco_outcome" --arg receiptStatus "$receipt_status" '
    {schemaVersion:1, kind:"vestiary-uninstall-plan",
     options:{keepIntegrations:$keepIntegrations,purge:$purge},
     receipt:$receipt, receiptStatus:$receiptStatus,
     resources:$resources,
     fresco:{app:$frescoApp,operation:$frescoOperation,outcome:$frescoOutcome,
       agentOperation:"remove-if-present"},
     runtime:$runtime,
     summary:{planned:([$resources[], $runtime[]]
         | map(select(.outcome == "planned")) | length)
         + (if $frescoOutcome == "planned" then 1 else 0 end),
       preserved:([$resources[], $runtime[]]
         | map(select(.outcome == "preserved")) | length)
         + (if $frescoOutcome == "preserved" then 1 else 0 end),
       blocked:([$resources[], $runtime[]]
         | map(select(.outcome == "blocked")) | length)}}
  '

  rm -f "$resource_actions" "$runtime_actions"
}
