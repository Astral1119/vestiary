#!/bin/sh

# Shared install ownership ledger. Callers must set REPO_ROOT before sourcing.

VESTIARY_CONFIG_ROOT=${VESTIARY_CONFIG_ROOT:-"$HOME/.config/vestiary"}
VESTIARY_RECEIPT_PATH=${VESTIARY_RECEIPT_PATH:-"$VESTIARY_CONFIG_ROOT/install-receipt.json"}
VESTIARY_BACKUP_DIR=${VESTIARY_BACKUP_DIR:-"$VESTIARY_CONFIG_ROOT/install-backups"}

file_digest() {
  shasum -a 256 "$1" | awk '{print $1}'
}

receipt_init() {
  mkdir -p "$VESTIARY_CONFIG_ROOT"
  if [ -e "$VESTIARY_RECEIPT_PATH" ]; then
    if jq -e '.schemaVersion == 1 and (.resources | type == "array")' \
      "$VESTIARY_RECEIPT_PATH" >/dev/null 2>&1; then
      return
    fi
    echo "install: refusing to replace invalid receipt at $VESTIARY_RECEIPT_PATH" >&2
    return 1
  fi

  receipt_tmp=$(mktemp "${TMPDIR:-/tmp}/vestiary-receipt.XXXXXX")
  jq -n --arg repositoryRoot "$REPO_ROOT" --arg installedAt "$(date -u +%FT%TZ)" \
    '{schemaVersion: 1, repositoryRoot: $repositoryRoot,
      installedAt: $installedAt, updatedAt: $installedAt, resources: []}' \
    > "$receipt_tmp"
  mv "$receipt_tmp" "$VESTIARY_RECEIPT_PATH"
}

# Merge one resource into the ledger. Identity is kind plus path, or kind plus
# host and id for editor extensions. Existing fields such as the original
# backup survive later installer runs.
receipt_record() {
  resource=$1
  receipt_tmp=$(mktemp "${TMPDIR:-/tmp}/vestiary-receipt.XXXXXX")
  jq --argjson resource "$resource" --arg repositoryRoot "$REPO_ROOT" \
    --arg updatedAt "$(date -u +%FT%TZ)" '
    def same($a; $b):
      $a.kind == $b.kind and
      (if $b.kind == "loader-line" then
         $a.path? == $b.path? and $a.line? == $b.line?
       elif ($b.path? != null) then $a.path? == $b.path
       else $a.host? == $b.host? and $a.id? == $b.id? end);
    .repositoryRoot = $repositoryRoot |
    .updatedAt = $updatedAt |
    .resources = ((([.resources[] | select(same(.; $resource))][0] // {}) * $resource) as $merged |
      ([.resources[] | select(same(.; $resource) | not)] + [$merged]))
  ' "$VESTIARY_RECEIPT_PATH" > "$receipt_tmp"
  mv "$receipt_tmp" "$VESTIARY_RECEIPT_PATH"
}

receipt_owns_path() {
  kind=$1
  path=$2
  [ -f "$VESTIARY_RECEIPT_PATH" ] && jq -e --arg kind "$kind" --arg path "$path" \
    '.resources[] | select(.kind == $kind and .path == $path)' \
    "$VESTIARY_RECEIPT_PATH" >/dev/null 2>&1
}

receipt_owns_extension() {
  host=$1
  id=$2
  [ -f "$VESTIARY_RECEIPT_PATH" ] && jq -e --arg host "$host" --arg id "$id" \
    '.resources[] | select(.kind == "editor-extension" and .host == $host and .id == $id)' \
    "$VESTIARY_RECEIPT_PATH" >/dev/null 2>&1
}
