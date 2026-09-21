#!/usr/bin/env bash
set -Eeuo pipefail

PINNED_REF="ca58adf56e198f16b6a42e05d8ae6475a1111865"
EXPECTED_BLOB_SHA="8b809eb1ded0f8b07788d67728ed36a00db55fd5"
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
exec bash "$TMP" migrate-existing
