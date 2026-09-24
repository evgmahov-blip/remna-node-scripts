#!/usr/bin/env bash
set -Eeuo pipefail

PINNED_REF="e4cfa4c779621d565a2e9c29707daafc301f1630"
EXPECTED_BLOB_SHA="75a48db8201d52b987e73f58f95dac4543144e74"
URL="https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/${PINNED_REF}/full-clean-reinstall.sh"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

git_blob_sha(){
  local file="$1" size
  size="$(wc -c <"$file" | tr -d '[:space:]')"
  { printf 'blob %s\000' "$size"; cat "$file"; } | sha1sum | awk '{print $1}'
}

command -v curl >/dev/null 2>&1 || {
  apt-get -o DPkg::Lock::Timeout=300 update -y
  apt-get -o DPkg::Lock::Timeout=300 install -y curl ca-certificates
}

curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 --retry 3 "$URL" -o "$TMP"
ACTUAL_BLOB_SHA="$(git_blob_sha "$TMP")"
[ "$ACTUAL_BLOB_SHA" = "$EXPECTED_BLOB_SHA" ] || {
  echo "[ERROR] Integrity check failed: $ACTUAL_BLOB_SHA != $EXPECTED_BLOB_SHA" >&2
  exit 1
}
bash -n "$TMP"
exec bash "$TMP" install
