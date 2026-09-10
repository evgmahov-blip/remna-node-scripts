#!/usr/bin/env bash
set -Eeuo pipefail

URL="https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/main/full-clean-reinstall.sh"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 --retry 3 "$URL" -o "$TMP"
bash -n "$TMP"
bash "$TMP" install
