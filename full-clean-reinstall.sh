#!/usr/bin/env bash
set -Eeuo pipefail

TASK_NAME="REMNA NODE FULL CLEAN + NEXT"
PINNED_REF="9f995774f85ddba77826444992725a6a51e2ac20"
REMOTE="https://raw.githubusercontent.com/evgmahov-blip/setup-remna-node/${PINNED_REF}/production/full-clean-reinstall.sh"
MODE="${1:-menu}"
TMP="$(mktemp)"

printf '#################### НАЧАЛО ВЫВОДА: %s ####################\n' "$TASK_NAME"
cleanup(){ rc=$?; rm -f "$TMP"; printf '#################### КОНЕЦ ВЫВОДА: %s ####################\n' "$TASK_NAME"; return "$rc"; }
trap cleanup EXIT

if [ "$(id -u)" -ne 0 ]; then
  echo '[ERROR] Запусти от root.' >&2
  exit 1
fi

command -v curl >/dev/null 2>&1 || { apt-get update -y && apt-get install -y curl ca-certificates; }

curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 --retry 3 "$REMOTE" -o "$TMP"
bash -n "$TMP"
chmod 0700 "$TMP"

case "$MODE" in
  clean|reinstall|full-reinstall|install|install-next|menu|'')
    bash "$TMP" "$MODE"
    ;;
  *)
    echo '[ERROR] Использование: full-clean-reinstall.sh [clean|reinstall|install|menu]' >&2
    exit 2
    ;;
esac
