#!/usr/bin/env bash
set -Eeuo pipefail

PINNED_REF="b0af607a7e2e3a45be8c341d98ac668d62f749b0"
EXPECTED_BLOB_SHA="b515b08c6844d01fa21ab28964afe65ca2994584"
URL="https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/${PINNED_REF}/full-clean-reinstall.sh"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

git_blob_sha(){
  local file="$1" size
  command -v sha1sum >/dev/null 2>&1 || return 1
  size="$(wc -c <"$file" | tr -d '[:space:]')"
  { printf 'blob %s\000' "$size"; cat "$file"; } | sha1sum | awk '{print $1}'
}

curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 --retry 3 "$URL" -o "$TMP"
ACTUAL_BLOB_SHA="$(git_blob_sha "$TMP")"
[ "$ACTUAL_BLOB_SHA" = "$EXPECTED_BLOB_SHA" ] || {
  echo "[ERROR] Integrity check failed: $ACTUAL_BLOB_SHA != $EXPECTED_BLOB_SHA" >&2
  exit 1
}
bash -n "$TMP"
exec bash "$TMP" reinstall
