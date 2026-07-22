#!/bin/sh
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/vestiary-install-state.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' 0

fail() {
  echo "install-state test: $*" >&2
  exit 1
}

CONFIG_ROOT="$TEST_ROOT/config"
export VESTIARY_CONFIG_ROOT="$CONFIG_ROOT"
export VESTIARY_RECEIPT_PATH="$CONFIG_ROOT/install-receipt.json"
export VESTIARY_BACKUP_DIR="$CONFIG_ROOT/install-backups"
. "$REPO_ROOT/setup/receipt.sh"
receipt_init

SHIM="$TEST_ROOT/bin/livery"
mkdir -p "$(dirname "$SHIM")"
printf '#!/bin/sh\nexit 0\n' > "$SHIM"
receipt_record "$(jq -n --arg id livery --arg path "$SHIM" \
  --arg digest "$(file_digest "$SHIM")" \
  '{kind:"shim",id:$id,path:$path,digest:$digest}')"

LOADER_REAL="$TEST_ROOT/dotfiles/tmux.conf"
LOADER="$TEST_ROOT/tmux.conf"
LINE='source-file -q ~/.config/livery/current/tmux/livery.conf'
mkdir -p "$(dirname "$LOADER_REAL")"
printf 'set -g mouse on\n%s\n' "$LINE" > "$LOADER_REAL"
ln -s "$LOADER_REAL" "$LOADER"
receipt_record "$(jq -n --arg id tmux --arg path "$LOADER" --arg line "$LINE" \
  '{kind:"loader-line",id:$id,path:$path,line:$line}')"

MANAGED="$TEST_ROOT/colors.lua"
BACKUP="$TEST_ROOT/original-colors.lua"
printf 'return { original = true }\n' > "$BACKUP"
printf 'return dofile("current")\n' > "$MANAGED"
receipt_record "$(jq -n --arg id sketchybar-colors --arg path "$MANAGED" \
  --arg digest "$(file_digest "$MANAGED")" --arg backup "$BACKUP" \
  --arg backupDigest "$(file_digest "$BACKUP")" \
  '{kind:"managed-file",id:$id,path:$path,digest:$digest,
    backup:$backup,backupDigest:$backupDigest}')"
receipt_record "$(jq -n --arg id sketchybar-colors --arg path "$MANAGED" \
  --arg digest "$(file_digest "$MANAGED")" \
  '{kind:"managed-file",id:$id,path:$path,digest:$digest}')"
jq -e --arg backup "$BACKUP" \
  '.resources[] | select(.kind == "managed-file" and .backup == $backup)' \
  "$VESTIARY_RECEIPT_PATH" >/dev/null \
  || fail "receipt update discarded the original backup"

FAKE_BIN="$TEST_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
CODE_LOG="$TEST_ROOT/code.log"
VSCODE_STATE="$TEST_ROOT/vscode-state.json"
export VESTIARY_VSCODE_STATE="$VSCODE_STATE"
printf '{"schemaVersion":1,"attached":false,"ownsColors":false}\n' > "$VSCODE_STATE"
cat > "$FAKE_BIN/code" <<EOF
#!/bin/sh
case \$1 in
  --list-extensions)
    [ "\${FAKE_CODE_ABSENT:-no}" = yes ] || echo vestiary.vestiary-vscode
    ;;
  --uninstall-extension) printf '%s\n' "\$2" >> "$CODE_LOG" ;;
esac
EOF
chmod +x "$FAKE_BIN/code"
receipt_record "$(jq -n \
  '{kind:"editor-extension",id:"vestiary.vestiary-vscode",host:"code",
    version:"0.1.0",installedByVestiary:true}')"

# Simulate a matching line added by the user after installation. Uninstall
# removes only the occurrence represented by the receipt.
printf '%s\n' "$LINE" >> "$LOADER"

PATH="$FAKE_BIN:$PATH" VESTIARY_SKIP_FRESCO=yes \
  VESTIARY_FRESCO_APP="$TEST_ROOT/Fresco.app" \
  "$REPO_ROOT/uninstall" --plan > "$TEST_ROOT/uninstall-plan.json"
jq -e '.kind == "vestiary-uninstall-plan"
  and .summary.blocked == 0
  and ([.resources[] | select(.resource.kind == "shim")][0].operation == "remove")
  and ([.resources[] | select(.resource.kind == "managed-file")][0].operation == "restore")
  and ([.resources[] | select(.resource.kind == "editor-extension")][0].operation == "uninstall")' \
  "$TEST_ROOT/uninstall-plan.json" >/dev/null \
  || fail "uninstall plan was incorrect"
[ -e "$SHIM" ] && [ -L "$LOADER" ] && [ -e "$MANAGED" ] \
  || fail "uninstall plan changed installed resources"

PATH="$FAKE_BIN:$PATH" VESTIARY_SKIP_FRESCO=yes \
  VESTIARY_FRESCO_APP="$TEST_ROOT/Fresco.app" \
  "$REPO_ROOT/uninstall" --keep-integrations >/dev/null
[ ! -e "$SHIM" ] || fail "owned shim was not removed"
grep -Fxq "$LINE" "$LOADER" || fail "--keep-integrations removed loader wiring"
[ "$(cat "$MANAGED")" = 'return dofile("current")' ] \
  || fail "--keep-integrations restored a managed file"
[ ! -e "$CODE_LOG" ] || fail "--keep-integrations removed the editor extension"
[ "$(jq '.resources | length' "$VESTIARY_RECEIPT_PATH")" -eq 3 ] \
  || fail "--keep-integrations changed integration ownership"

PATH="$FAKE_BIN:$PATH" VESTIARY_SKIP_FRESCO=yes \
  VESTIARY_FRESCO_APP="$TEST_ROOT/Fresco.app" \
  "$REPO_ROOT/uninstall" >/dev/null

[ -L "$LOADER" ] || fail "loader edit replaced a symlink"
[ "$(grep -Fxc "$LINE" "$LOADER")" -eq 1 ] \
  || fail "loader removal did not preserve the later duplicate"
[ "$(cat "$MANAGED")" = 'return { original = true }' ] \
  || fail "managed file was not restored"
grep -Fxq vestiary.vestiary-vscode "$CODE_LOG" \
  || fail "owned extension was not removed"
[ ! -e "$VESTIARY_RECEIPT_PATH" ] || fail "empty receipt was not removed"

receipt_init
printf '#!/bin/sh\nexit 0\n' > "$SHIM"
receipt_record "$(jq -n --arg id livery --arg path "$SHIM" \
  --arg digest "$(file_digest "$SHIM")" \
  '{kind:"shim",id:$id,path:$path,digest:$digest}')"
printf '# user change\n' >> "$SHIM"
VESTIARY_SKIP_FRESCO=yes VESTIARY_FRESCO_APP="$TEST_ROOT/Fresco.app" \
  "$REPO_ROOT/uninstall" >/dev/null
[ -e "$SHIM" ] || fail "modified shim was removed"
jq -e '.resources[] | select(.kind == "shim")' "$VESTIARY_RECEIPT_PATH" \
  >/dev/null || fail "modified shim disappeared from receipt"

receipt_record "$(jq -n \
  '{kind:"editor-extension",id:"vestiary.vestiary-vscode",host:"code",
    version:"0.1.0",installedByVestiary:true}')"
printf '{"schemaVersion":1,"attached":true,"ownsColors":true}\n' > "$VSCODE_STATE"
uninstall_count=$(wc -l < "$CODE_LOG" | tr -d ' ')
PATH="$FAKE_BIN:$PATH" FAKE_CODE_ABSENT=yes VESTIARY_SKIP_FRESCO=yes \
  VESTIARY_FRESCO_APP="$TEST_ROOT/Fresco.app" \
  "$REPO_ROOT/uninstall" --plan --purge > "$TEST_ROOT/absent-vscode-plan.json"
jq -e '([.resources[] | select(.resource.kind == "editor-extension")][0].outcome
    == "blocked")
  and ([.runtime[] | select(.id == "vestiary")][0].outcome == "blocked")' \
  "$TEST_ROOT/absent-vscode-plan.json" >/dev/null \
  || fail "uninstall plan ignored attached colors for an absent extension"
PATH="$FAKE_BIN:$PATH" VESTIARY_SKIP_FRESCO=yes \
  VESTIARY_FRESCO_APP="$TEST_ROOT/Fresco.app" \
  "$REPO_ROOT/uninstall" >/dev/null
[ "$(wc -l < "$CODE_LOG" | tr -d ' ')" -eq "$uninstall_count" ] \
  || fail "attached VS Code integration was removed"
jq -e '.resources[] | select(.kind == "editor-extension")' \
  "$VESTIARY_RECEIPT_PATH" >/dev/null \
  || fail "attached VS Code integration disappeared from receipt"

LIVERY_DATA="$TEST_ROOT/livery-data"
FRESCO_DATA="$TEST_ROOT/fresco-data"
FRESCO_COMPAT="$TEST_ROOT/fresco-compat"
mkdir -p "$LIVERY_DATA" "$FRESCO_DATA" "$FRESCO_COMPAT"
VESTIARY_SKIP_FRESCO=yes VESTIARY_FRESCO_APP="$TEST_ROOT/Fresco.app" \
  LIVERY_RUNTIME_ROOT="$LIVERY_DATA" FRESCO_STATE_DIR="$FRESCO_DATA" \
  FRESCO_COMPAT_DIR="$FRESCO_COMPAT" \
  "$REPO_ROOT/uninstall" --purge >/dev/null
[ ! -e "$LIVERY_DATA" ] || fail "--purge kept Livery data"
[ ! -e "$FRESCO_DATA" ] || fail "--purge kept Fresco data"
[ ! -e "$FRESCO_COMPAT" ] || fail "--purge kept the compatibility path"
[ -e "$VESTIARY_RECEIPT_PATH" ] \
  || fail "--purge discarded a receipt with unresolved resources"

if VESTIARY_CONFIG_ROOT="$HOME/" \
  VESTIARY_RECEIPT_PATH="$TEST_ROOT/no-receipt.json" \
  VESTIARY_SKIP_FRESCO=yes VESTIARY_FRESCO_APP="$TEST_ROOT/Fresco.app" \
  LIVERY_RUNTIME_ROOT="$TEST_ROOT/no-livery" \
  FRESCO_STATE_DIR="$TEST_ROOT/no-fresco" \
  FRESCO_COMPAT_DIR="$TEST_ROOT/no-compat" \
  "$REPO_ROOT/uninstall" --purge >/dev/null 2>&1; then
  fail "--purge accepted the home directory with a trailing slash"
fi

INVALID_ROOT="$TEST_ROOT/invalid-receipt"
mkdir -p "$INVALID_ROOT"
printf '{not-json\n' > "$INVALID_ROOT/install-receipt.json"
VESTIARY_CONFIG_ROOT="$INVALID_ROOT" \
  VESTIARY_RECEIPT_PATH="$INVALID_ROOT/install-receipt.json" \
  VESTIARY_SKIP_FRESCO=yes VESTIARY_FRESCO_APP="$TEST_ROOT/Fresco.app" \
  LIVERY_RUNTIME_ROOT="$TEST_ROOT/invalid-livery" \
  FRESCO_STATE_DIR="$TEST_ROOT/invalid-fresco" \
  FRESCO_COMPAT_DIR="$TEST_ROOT/invalid-compat" \
  "$REPO_ROOT/uninstall" --plan --purge > "$TEST_ROOT/invalid-receipt-plan.json"
jq -e '.receiptStatus == "invalid"
  and ([.runtime[] | select(.id == "vestiary")][0].outcome == "blocked")' \
  "$TEST_ROOT/invalid-receipt-plan.json" >/dev/null \
  || fail "invalid receipt was not protected in uninstall plan"
VESTIARY_CONFIG_ROOT="$INVALID_ROOT" \
  VESTIARY_RECEIPT_PATH="$INVALID_ROOT/install-receipt.json" \
  VESTIARY_SKIP_FRESCO=yes VESTIARY_FRESCO_APP="$TEST_ROOT/Fresco.app" \
  LIVERY_RUNTIME_ROOT="$TEST_ROOT/invalid-livery" \
  FRESCO_STATE_DIR="$TEST_ROOT/invalid-fresco" \
  FRESCO_COMPAT_DIR="$TEST_ROOT/invalid-compat" \
  "$REPO_ROOT/uninstall" --purge >/dev/null
[ -e "$INVALID_ROOT/install-receipt.json" ] \
  || fail "purge removed an invalid receipt"

NO_CODE_ROOT="$TEST_ROOT/no-code-plan"
mkdir -p "$NO_CODE_ROOT/bin" "$NO_CODE_ROOT/config/vestiary"
ln -s "$(command -v jq)" "$NO_CODE_ROOT/bin/jq"
cat > "$NO_CODE_ROOT/config/vestiary/install-receipt.json" <<'JSON'
{
  "schemaVersion": 1,
  "resources": [
    {"kind":"editor-extension","id":"vestiary.vestiary-vscode","host":"code"}
  ]
}
JSON
PATH="$NO_CODE_ROOT/bin:/usr/bin:/bin" \
  VESTIARY_CONFIG_ROOT="$NO_CODE_ROOT/config/vestiary" \
  VESTIARY_RECEIPT_PATH="$NO_CODE_ROOT/config/vestiary/install-receipt.json" \
  LIVERY_CONFIG_ROOT="$NO_CODE_ROOT/config" \
  LIVERY_RUNTIME_ROOT="$NO_CODE_ROOT/config/livery" \
  "$REPO_ROOT/install" --plan > "$NO_CODE_ROOT/plan.json"
jq -e '(.readyToApply == false)
  and ([.integrations[] | select(.id == "vscode")][0].blockedReason
    == "host-command-unavailable")' "$NO_CODE_ROOT/plan.json" >/dev/null \
  || fail "managed unavailable VS Code did not block setup readiness"

NO_CSS_ROOT="$TEST_ROOT/no-css-plan"
mkdir -p "$NO_CSS_ROOT/adapters" "$NO_CSS_ROOT/config/vestiary"
cat > "$NO_CSS_ROOT/adapters/custom" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$NO_CSS_ROOT/adapters/custom"
LIVERY_ADAPTER_PATH="$NO_CSS_ROOT/adapters" \
  VESTIARY_CONFIG_ROOT="$NO_CSS_ROOT/config/vestiary" \
  VESTIARY_RECEIPT_PATH="$NO_CSS_ROOT/config/vestiary/install-receipt.json" \
  LIVERY_CONFIG_ROOT="$NO_CSS_ROOT/config" \
  "$REPO_ROOT/install" --plan > "$NO_CSS_ROOT/plan.json"
jq -e '(.readyToApply == false) and (.state.cssAvailable == false)' \
  "$NO_CSS_ROOT/plan.json" >/dev/null \
  || fail "missing CSS adapter did not block setup readiness"

MATUGEN_ROOT="$TEST_ROOT/matugen-preflight"
mkdir -p "$MATUGEN_ROOT/config/vestiary"
cat > "$MATUGEN_ROOT/selection.json" <<'JSON'
{
  "schemaVersion": 1,
  "kind": "vestiary-setup-selection",
  "adapters": ["css"],
  "wireLoaders": false,
  "integrations": {"vscode": false}
}
JSON
if PATH="$NO_CODE_ROOT/bin:/usr/bin:/bin" \
  VESTIARY_TEST_ARCH=x86_64 VESTIARY_MATUGEN="$MATUGEN_ROOT/missing-matugen" \
  VESTIARY_CONFIG_ROOT="$MATUGEN_ROOT/config/vestiary" \
  VESTIARY_RECEIPT_PATH="$MATUGEN_ROOT/config/vestiary/install-receipt.json" \
  LIVERY_CONFIG_ROOT="$MATUGEN_ROOT/config" \
  "$REPO_ROOT/install" --apply "$MATUGEN_ROOT/selection.json" >/dev/null 2>&1; then
  fail "setup apply ignored missing local Matugen prerequisites"
fi
[ ! -e "$MATUGEN_ROOT/config/vestiary/install-receipt.json" ] \
  && [ ! -e "$MATUGEN_ROOT/config/vestiary/targets.json" ] \
  || fail "failed Matugen preflight wrote setup state"

INSTALL_ROOT="$TEST_ROOT/install-round-trip"
INSTALL_CONFIG="$INSTALL_ROOT/config"
INSTALL_USER_CONFIG="$INSTALL_ROOT/user-config"
INSTALL_SHIM="$INSTALL_USER_CONFIG/sketchybar/colors.lua"
mkdir -p "$INSTALL_CONFIG/vestiary" "$INSTALL_ROOT/bin"
mkdir -p "$INSTALL_CONFIG/vestiary/adapters.d"
cat > "$INSTALL_ROOT/selection.json" <<'JSON'
{
  "schemaVersion": 1,
  "kind": "vestiary-setup-selection",
  "adapters": ["css", "sketchybar", "custom-target"],
  "wireLoaders": true,
  "integrations": {"vscode": false}
}
JSON
cat > "$INSTALL_ROOT/bin/sketchybar" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$INSTALL_ROOT/bin/sketchybar"
cat > "$INSTALL_CONFIG/vestiary/adapters.d/custom-target" <<'SH'
#!/bin/sh
case ${1:-} in
  loader-check) exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$INSTALL_CONFIG/vestiary/adapters.d/custom-target"
cat > "$INSTALL_CONFIG/vestiary/adapters.d/custom-target.target.json" <<'JSON'
{
  "schemaVersion": 1,
  "id": "custom-target",
  "displayName": "Custom target",
  "kind": "adapter",
  "consumes": [],
  "detect": {}
}
JSON

PATH="$INSTALL_ROOT/bin:$PATH" \
  VESTIARY_CONFIG_ROOT="$INSTALL_CONFIG/vestiary" \
  VESTIARY_RECEIPT_PATH="$INSTALL_CONFIG/vestiary/install-receipt.json" \
  VESTIARY_BACKUP_DIR="$INSTALL_CONFIG/vestiary/install-backups" \
  VESTIARY_SHIM_DIR="$INSTALL_ROOT/shims" \
  VESTIARY_USER_CONFIG_ROOT="$INSTALL_USER_CONFIG" \
  LIVERY_CONFIG_ROOT="$INSTALL_CONFIG" \
  LIVERY_RUNTIME_ROOT="$INSTALL_CONFIG/livery" \
  LIVERY_SKETCHYBAR_SHIM="$INSTALL_SHIM" \
  "$REPO_ROOT/install" --plan > "$INSTALL_ROOT/plan.json"
jq -e '.kind == "vestiary-setup-plan"
  and .system.compatible
  and (.selection.adapters == ["css"])
  and ([.integrations[] | select(.id == "sketchybar")][0].detected)
  and ([.integrations[] | select(.id == "custom-target")][0].detected)' \
  "$INSTALL_ROOT/plan.json" >/dev/null || fail "install plan was incorrect"
[ ! -e "$INSTALL_CONFIG/vestiary/install-receipt.json" ] \
  || fail "install plan created a receipt"
[ ! -e "$INSTALL_CONFIG/vestiary/targets.json" ] \
  || fail "install plan created target selection"
if PATH="$INSTALL_ROOT/bin:$PATH" \
  VESTIARY_CONFIG_ROOT="$INSTALL_CONFIG/vestiary" \
  VESTIARY_RECEIPT_PATH="$INSTALL_CONFIG/vestiary/install-receipt.json" \
  LIVERY_CONFIG_ROOT="$INSTALL_CONFIG" LIVERY_RUNTIME_ROOT="$INSTALL_CONFIG/livery" \
  "$REPO_ROOT/install" --plan --apply "$INSTALL_ROOT/selection.json" \
    >/dev/null 2>&1; then
  fail "install accepted conflicting plan and apply modes"
fi
[ ! -e "$INSTALL_CONFIG/vestiary/install-receipt.json" ] \
  || fail "conflicting setup modes created a receipt"

printf '{"enabled":null,"disabled":[]}\n' > "$INSTALL_CONFIG/vestiary/targets.json"
PATH="$INSTALL_ROOT/bin:$PATH" \
  VESTIARY_CONFIG_ROOT="$INSTALL_CONFIG/vestiary" \
  VESTIARY_RECEIPT_PATH="$INSTALL_CONFIG/vestiary/install-receipt.json" \
  LIVERY_CONFIG_ROOT="$INSTALL_CONFIG" LIVERY_RUNTIME_ROOT="$INSTALL_CONFIG/livery" \
  "$REPO_ROOT/install" --plan > "$INSTALL_ROOT/invalid-targets-plan.json"
jq -e '(.readyToApply == false)
  and (.state.targetsStatus == "invalid")
  and (.selection.adapters == ["css"])' \
  "$INSTALL_ROOT/invalid-targets-plan.json" >/dev/null \
  || fail "invalid targets produced a ready or invalid repair plan"
if PATH="$INSTALL_ROOT/bin:$PATH" \
  VESTIARY_CONFIG_ROOT="$INSTALL_CONFIG/vestiary" \
  VESTIARY_RECEIPT_PATH="$INSTALL_CONFIG/vestiary/install-receipt.json" \
  LIVERY_CONFIG_ROOT="$INSTALL_CONFIG" LIVERY_RUNTIME_ROOT="$INSTALL_CONFIG/livery" \
  "$REPO_ROOT/install" --apply "$INSTALL_ROOT/invalid-targets-plan.json" \
    >/dev/null 2>&1; then
  fail "install applied a setup plan marked not ready"
fi
[ ! -e "$INSTALL_CONFIG/vestiary/install-receipt.json" ] \
  || fail "not-ready setup plan created a receipt"

if ! PATH="$INSTALL_ROOT/bin:$PATH" \
  VESTIARY_CONFIG_ROOT="$INSTALL_CONFIG/vestiary" \
  VESTIARY_RECEIPT_PATH="$INSTALL_CONFIG/vestiary/install-receipt.json" \
  VESTIARY_BACKUP_DIR="$INSTALL_CONFIG/vestiary/install-backups" \
  VESTIARY_SHIM_DIR="$INSTALL_ROOT/shims" \
  VESTIARY_USER_CONFIG_ROOT="$INSTALL_USER_CONFIG" \
  LIVERY_CONFIG_ROOT="$INSTALL_CONFIG" \
  LIVERY_RUNTIME_ROOT="$INSTALL_CONFIG/livery" \
  LIVERY_SKETCHYBAR_SHIM="$INSTALL_SHIM" \
  "$REPO_ROOT/install" --apply "$INSTALL_ROOT/selection.json" \
    >"$INSTALL_ROOT/first-install.log" 2>&1; then
  sed -n '1,240p' "$INSTALL_ROOT/first-install.log" >&2
  fail "isolated installer run failed"
fi
jq -e '.enabled == ["css", "sketchybar", "custom-target"]' \
  "$INSTALL_CONFIG/vestiary/targets.json" >/dev/null \
  || fail "setup apply omitted the external adapter"
PATH="$INSTALL_ROOT/bin:$PATH" \
  VESTIARY_CONFIG_ROOT="$INSTALL_CONFIG/vestiary" \
  VESTIARY_RECEIPT_PATH="$INSTALL_CONFIG/vestiary/install-receipt.json" \
  LIVERY_CONFIG_ROOT="$INSTALL_CONFIG" LIVERY_RUNTIME_ROOT="$INSTALL_CONFIG/livery" \
  "$REPO_ROOT/install" --plan > "$INSTALL_ROOT/applied-plan.json"
jq -e '.readyToApply and .state.targetsStatus == "present"
  and (.selection.adapters == ["css", "sketchybar", "custom-target"])' \
  "$INSTALL_ROOT/applied-plan.json" >/dev/null \
  || fail "applied target selection did not round-trip through planning"
printf 'return { user_modified = true }\n' > "$INSTALL_SHIM"
if ! PATH="$INSTALL_ROOT/bin:$PATH" \
  VESTIARY_CONFIG_ROOT="$INSTALL_CONFIG/vestiary" \
  VESTIARY_RECEIPT_PATH="$INSTALL_CONFIG/vestiary/install-receipt.json" \
  VESTIARY_BACKUP_DIR="$INSTALL_CONFIG/vestiary/install-backups" \
  VESTIARY_SHIM_DIR="$INSTALL_ROOT/shims" \
  VESTIARY_USER_CONFIG_ROOT="$INSTALL_USER_CONFIG" \
  LIVERY_CONFIG_ROOT="$INSTALL_CONFIG" \
  LIVERY_RUNTIME_ROOT="$INSTALL_CONFIG/livery" \
  LIVERY_SKETCHYBAR_SHIM="$INSTALL_SHIM" \
  "$REPO_ROOT/install" --apply "$INSTALL_ROOT/selection.json" \
    >"$INSTALL_ROOT/second-install.log" 2>&1; then
  sed -n '1,240p' "$INSTALL_ROOT/second-install.log" >&2
  fail "isolated reinstall failed"
fi
[ "$(cat "$INSTALL_SHIM")" = 'return { user_modified = true }' ] \
  || fail "reinstall overwrote a modified managed loader"

echo "install-state test: ok"
