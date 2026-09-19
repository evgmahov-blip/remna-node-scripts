#!/usr/bin/env bash
set -Eeuo pipefail

TASK_NAME="REMNA NODE VERIFIED INSTALLER"
PINNED_REF="bc9deff3cc8de8a159c18b8b99b563b8b13ec19f"
EXPECTED_BLOB_SHA="b89a4cdc215d1e3878aeb6e99a3db6ca4c6aeeb3"
REMOTE="https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/${PINNED_REF}/install-caddy-node-reality-stream.sh"
MODE="${1:-menu}"
TMP="$(mktemp)"

printf '#################### НАЧАЛО ВЫВОДА: %s ####################\n' "$TASK_NAME"
cleanup(){ rc=$?; rm -f "$TMP"; printf '#################### КОНЕЦ ВЫВОДА: %s ####################\n' "$TASK_NAME"; return "$rc"; }
trap cleanup EXIT

if [ "$(id -u)" -ne 0 ]; then
  echo '[ERROR] Запусти от root.' >&2
  exit 1
fi

command -v curl >/dev/null 2>&1 || {
  command -v apt-get >/dev/null 2>&1 || { echo '[ERROR] curl отсутствует и apt-get недоступен.' >&2; exit 1; }
  apt-get -o DPkg::Lock::Timeout=300 update -y
  apt-get -o DPkg::Lock::Timeout=300 install -y curl ca-certificates
}

git_blob_sha(){
  local file="$1" size
  command -v sha1sum >/dev/null 2>&1 || return 1
  size="$(wc -c <"$file" | tr -d '[:space:]')"
  { printf 'blob %s\000' "$size"; cat "$file"; } | sha1sum | awk '{print $1}'
}

curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 --retry 3 "$REMOTE" -o "$TMP"
ACTUAL_BLOB_SHA="$(git_blob_sha "$TMP")"
[ "$ACTUAL_BLOB_SHA" = "$EXPECTED_BLOB_SHA" ] || {
  echo "[ERROR] Integrity check failed: $ACTUAL_BLOB_SHA != $EXPECTED_BLOB_SHA" >&2
  exit 1
}
bash -n "$TMP"
chmod 0700 "$TMP"

case "$MODE" in
  install|reinstall|clean|menu|'')
    bash "$TMP" "${MODE:-menu}"
    ;;
  full-reinstall)
    bash "$TMP" reinstall
    ;;
  install-next)
    echo '[WARN] install-next больше не использует закрытый setup-remna-node; запускаю проверяемый public installer.' >&2
    bash "$TMP" install
    ;;
  *)
    echo '[ERROR] Использование: full-clean-reinstall.sh [install|reinstall|clean|menu]' >&2
    exit 2
    ;;
esac
