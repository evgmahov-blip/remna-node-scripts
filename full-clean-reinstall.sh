#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

TASK_NAME="REMNA NODE NEXT"
REPO="evgmahov-blip/remna-node-scripts"
SOURCE_REF="721269e2c48e31b7cac86e04bc14c46b33e31e72"
SOURCE_BLOB_SHA="51a91d5745d0bea9b03eefeeaac52677fcf56b60"
SOURCE_URL="https://raw.githubusercontent.com/${REPO}/${SOURCE_REF}/vendor/remna-next-source.tar.gz"
NODE_IMAGE_VERSION="3.4.1"
NODE_IMAGE_DIGEST="sha256:0cdf386dd49f360fc885bb34bde21132e478e40f0deac62d616086ec0fa9257e"
NODE_IMAGE="ghcr.io/remnawave/node:${NODE_IMAGE_VERSION}@${NODE_IMAGE_DIGEST}"
HYSTERIA_OVERLAY_REF="6f02c87c10d1d47fb4abcb234755823d1a1067bf"
HYSTERIA_OVERLAY_BLOB_SHA="62ff1364c26d88f357968422d5591b3d2b8d9e78"
HYSTERIA_OVERLAY_URL="https://raw.githubusercontent.com/${REPO}/${HYSTERIA_OVERLAY_REF}/next-installer/remnawave-transport-manager.sh"
V2_CLEANUP_REF="f7c609b0fa929cecc4a74db5bafe90b0a4d782be"
V2_CLEANUP_BLOB_SHA="3c9e7f15862048f8c4bd1fc96be58483872f6d4a"
V2_CLEANUP_URL="https://raw.githubusercontent.com/${REPO}/${V2_CLEANUP_REF}/next-installer/existing-node-v2-cleanup.sh"
NETWORK_REF="8378a6b4340fc0b11b3f66246caaa39d3ee360b9"
NETWORK_BLOB_SHA="a5157e7c48f3e2a1c4df4676ecd4a51511d15949"
NETWORK_URL="https://raw.githubusercontent.com/${REPO}/${NETWORK_REF}/next-installer/network-tuning-manager.sh"
TESTER_REF="bc240a3187c5c33cf5c56d2659059bc782e67f9e"
TESTER_BLOB_SHA="2e4f39cb660cc4ca3da6280a90c8fc518498dbed"
TESTER_URL="https://raw.githubusercontent.com/${REPO}/${TESTER_REF}/next-installer/server-multitest.sh"

MGMT_OVERLAY_REF="f7c609b0fa929cecc4a74db5bafe90b0a4d782be"
PROTECTION_BLOB_SHA="d38486200c4399ec3150e0c3185d7f5620a3606a"
SECURITY_SH_BLOB_SHA="74307541e6f3339fe7ac34278903a202157cf98f"
SECURITY_PY_BLOB_SHA="a1d7ba1464516da3568dee0d8e8caa24b42ae2d0"
TELEMT_BLOB_SHA="35e2e1674e995155feef881f9ec4addbbbeaa9ad"
TELEMT_LEGACY_BLOB_SHA="4d75a0ce34ff615fb7006a4e89a2cb619850c9ab"
REBUILD_BLOB_SHA="07b265e96f598266a6953c08adbb26b9a20ed5a2"

APP_DIR="/opt/remnanode"
NEXT_DIR="$APP_DIR/next-installer"
CLI="/usr/local/bin/remnanode-next"
SELF="/usr/local/libexec/remnanode-next.sh"
LEGACY="$NEXT_DIR/setup_node-legacy.sh"
TRANSPORT="$NEXT_DIR/remnawave-transport-manager.sh"
SELFSTEAL="$NEXT_DIR/selfsteal-site-manager.sh"
RKN="$NEXT_DIR/rkn-watcher-manager.sh"
GUARDS="$NEXT_DIR/next-runtime-guards.sh"
SIGNATURE="$NEXT_DIR/xhttp-signature-manager.sh"
V2_CLEANER="$NEXT_DIR/existing-node-v2-cleanup.sh"
NETWORK="$NEXT_DIR/network-tuning-manager.sh"
TESTER="$NEXT_DIR/server-multitest.sh"
PROTECTION="$APP_DIR/protection-manager.sh"
SECURITY_DIR="$APP_DIR/security"
TELEMT="$NEXT_DIR/telemt-manager.sh"
TELEMT_LEGACY="$NEXT_DIR/telemt-legacy-rkn-adapter.sh"
REBUILD="$NEXT_DIR/legacy-rebuild-manager.sh"
RELEASE_MARKER="$APP_DIR/.ainoc-release.json"
MANAGED_UPDATE_BACKUP_ROOT="${MANAGED_UPDATE_BACKUP_ROOT:-/root/remnanode-managed-updates}"
MANAGED_UPDATE_RUNTIME_DIR="${MANAGED_UPDATE_RUNTIME_DIR:-/run}"
TELEMT_CONFIG_FILE="${TELEMT_CONFIG_FILE:-/etc/telemt/telemt.toml}"
TELEMT_PANEL_CONFIG_FILE="${TELEMT_PANEL_CONFIG_FILE:-/etc/telemt-panel/config.toml}"
TTY=/dev/tty
[[ -r "$TTY" ]] || TTY=/dev/stdin

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET="$(printf '\033[0m')"
  C_BOLD="$(printf '\033[1m')"
  C_CYAN="$(printf '\033[36m')"
  C_GREEN="$(printf '\033[32m')"
  C_YELLOW="$(printf '\033[33m')"
  C_RED="$(printf '\033[31m')"
  C_GRAY="$(printf '\033[90m')"
else
  C_RESET=""
  C_BOLD=""
  C_CYAN=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
  C_GRAY=""
fi

EXPECTED_SETUP="728ed22841a1c494a9d9fce026109f6151fe16a2b861496d267005bd4850477c"
EXPECTED_GUARDS="620797d0677d091d6550894e32fea58ce7f2adf2f125d6f6ccfb217a7b3382fd"
EXPECTED_TRANSPORT="441c82fb0eb3b155986d7b84bd66aa82bb1d028b8a9c49e02f1fbac326fac2e2"
EXPECTED_RKN="2d5838809881a00cac755b43606d7c929e7ba8f5786f64ebff849eb73edeb3e7"
EXPECTED_SELFSTEAL="b783e94f2ef3764b2e397cba9eb96aeab88d7da11da017a2c867054f9546a84a"
EXPECTED_SIGNATURE="dbbd1110aec2e6dd32aee204b6d0174d7fe511e1b97118570cbbea553946bd4a"

say(){ printf '%s\n' "$*"; }
ok(){ printf '[OK] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
pause(){ printf 'Enter — продолжить... '; read -r _ < "$TTY" || true; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Запусти от root.'; }
apt_get(){ DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 "$@"; }

git_blob_sha(){
  local file="$1" size
  size="$(wc -c <"$file" | tr -d '[:space:]')"
  { printf 'blob %s\000' "$size"; cat "$file"; } | sha1sum | awk '{print $1}'
}

ensure_bootstrap_deps(){
  local missing=0
  for c in curl tar sha256sum sed awk diff python3; do command -v "$c" >/dev/null 2>&1 || missing=1; done
  if (( missing )); then
    if [[ "${AINOC_INPLACE_UPDATE:-0}" == "1" ]]; then
      die 'Safe in-place update: не хватает bootstrap-зависимостей; автоматическая установка пакетов запрещена.'
    fi
    command -v apt-get >/dev/null 2>&1 || die 'Не хватает bootstrap-зависимостей и apt-get недоступен.'
    apt_get update -y
    apt_get install -y curl ca-certificates tar gzip coreutils diffutils python3
  fi
}

verify_source_file(){
  local file="$1" expected="$2" got
  [[ -s "$file" ]] || die "В NEXT bundle отсутствует $(basename "$file")"
  got="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$got" == "$expected" ]] || die "SHA256 mismatch: $(basename "$file"): $got != $expected"
  bash -n "$file" || die "bash -n failed: $(basename "$file")"
}

sync_next_sources(){
  ensure_bootstrap_deps
  local tmp bundle listing
  tmp="$(mktemp -d)"
  bundle="$tmp/source.tar.gz"

  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 90 --retry 3 \
    "$SOURCE_URL" -o "$bundle" || die 'Не удалось скачать закреплённый NEXT source bundle.'
  [[ "$(git_blob_sha "$bundle")" == "$SOURCE_BLOB_SHA" ]] || die 'NEXT source bundle не прошёл Git blob SHA.'

  listing="$tmp/listing.txt"
  tar -tzf "$bundle" | sed '/\/$/d' | LC_ALL=C sort > "$listing"
  cat > "$tmp/expected.txt" <<'FILES'
docker-compose.yml
next-installer/next-runtime-guards.sh
next-installer/remnawave-transport-manager.sh
next-installer/rkn-watcher-manager.sh
next-installer/selfsteal-site-manager.sh
next-installer/setup_node-legacy.sh
next-installer/xhttp-signature-manager.sh
nginx.conf
FILES
  if ! diff -u "$tmp/expected.txt" "$listing"; then
    die 'Состав NEXT source bundle отличается от ожидаемого.'
  fi

  tar -xzf "$bundle" -C "$tmp"
  verify_source_file "$tmp/next-installer/setup_node-legacy.sh" "$EXPECTED_SETUP"

  # Keep the immutable source bundle, but replace its mutable Remnawave image tag
  # only after the original bundle and setup script have passed integrity checks.
  sed -i "s#ghcr.io/remnawave/node:latest#${NODE_IMAGE}#g" \
    "$tmp/docker-compose.yml" "$tmp/next-installer/setup_node-legacy.sh"
  grep -Fq "$NODE_IMAGE" "$tmp/docker-compose.yml" || die 'Pinned Remnawave image missing from docker-compose.yml.'
  grep -Fq "$NODE_IMAGE" "$tmp/next-installer/setup_node-legacy.sh" || die 'Pinned Remnawave image missing from setup_node-legacy.sh.'
  ! grep -R -Fq 'ghcr.io/remnawave/node:latest' "$tmp/docker-compose.yml" "$tmp/next-installer/setup_node-legacy.sh" \
    || die 'Mutable Remnawave node:latest reference remains after pin overlay.'
  bash -n "$tmp/next-installer/setup_node-legacy.sh" || die 'Pinned setup_node-legacy.sh failed bash -n.'

  verify_source_file "$tmp/next-installer/next-runtime-guards.sh" "$EXPECTED_GUARDS"
  verify_source_file "$tmp/next-installer/remnawave-transport-manager.sh" "$EXPECTED_TRANSPORT"

  local overlay
  overlay="$tmp/remnawave-transport-manager.fixed.sh"
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 --retry 3 \
    "$HYSTERIA_OVERLAY_URL" -o "$overlay" || die 'Не удалось скачать Hysteria2 transport overlay.'
  [[ "$(git_blob_sha "$overlay")" == "$HYSTERIA_OVERLAY_BLOB_SHA" ]] || die 'Hysteria2 transport overlay не прошёл Git blob SHA.'
  bash -n "$overlay" || die 'Hysteria2 transport overlay не прошёл bash -n.'
  install -m 0700 "$overlay" "$tmp/next-installer/remnawave-transport-manager.sh"
  grep -Fq '"clients": []' "$tmp/next-installer/remnawave-transport-manager.sh" || die 'Hysteria2 overlay: clients[] отсутствует.'
  grep -Fq '"routeOnly": true' "$tmp/next-installer/remnawave-transport-manager.sh" || die 'Hysteria2 overlay: sniffing/routeOnly отсутствует.'
  grep -Fq '"minVersion": "1.2"' "$tmp/next-installer/remnawave-transport-manager.sh" || die 'Hysteria2 overlay: TLS minVersion 1.2 отсутствует.'
  grep -Fq '"maxVersion": "1.3"' "$tmp/next-installer/remnawave-transport-manager.sh" || die 'Hysteria2 overlay: TLS maxVersion 1.3 отсутствует.'
  grep -Fq '"rejectUnknownSni": true' "$tmp/next-installer/remnawave-transport-manager.sh" || die 'Hysteria2 overlay: rejectUnknownSni отсутствует.'
  grep -Fq '"enableSessionResumption": true' "$tmp/next-installer/remnawave-transport-manager.sh" || die 'Hysteria2 overlay: session resumption отсутствует.'
  grep -Fq 'Final Mask: ПУСТО / DEFAULT' "$tmp/next-installer/remnawave-transport-manager.sh" || die 'Hysteria2 overlay: Host final-mask guidance отсутствует.'
  grep -Fq 'verify_hysteria_profile_shape' "$tmp/next-installer/remnawave-transport-manager.sh" || die 'Hysteria2 overlay: profile guard отсутствует.'
  grep -Fq 'Mapper: ПУСТО.' "$tmp/next-installer/remnawave-transport-manager.sh" || die 'Transport overlay: Remnawave VLESS mapper guard отсутствует.'
  grep -Fq 'settings.vnext ДОЛЖЕН содержать РОВНО 1 endpoint' "$tmp/next-installer/remnawave-transport-manager.sh" || die 'Transport overlay: VLESS vnext guard отсутствует.'
  ok 'Hysteria2 transport overlay применён: Remnawave clients[] + mobile-compatible TLS/sniffing + profile guard.'

  verify_source_file "$tmp/next-installer/rkn-watcher-manager.sh" "$EXPECTED_RKN"
  verify_source_file "$tmp/next-installer/selfsteal-site-manager.sh" "$EXPECTED_SELFSTEAL"
  verify_source_file "$tmp/next-installer/xhttp-signature-manager.sh" "$EXPECTED_SIGNATURE"

  local v2cleanup
  v2cleanup="$tmp/next-installer/existing-node-v2-cleanup.sh"
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 --retry 3 \
    "$V2_CLEANUP_URL" -o "$v2cleanup" || die 'Не удалось скачать NEXT V2 cleanup module.'
  [[ "$(git_blob_sha "$v2cleanup")" == "$V2_CLEANUP_BLOB_SHA" ]] || die 'NEXT V2 cleanup module не прошёл Git blob SHA.'
  bash -n "$v2cleanup" || die 'NEXT V2 cleanup module не прошёл bash -n.'
  grep -Fq 'V2 POSTCHECK PASS' "$v2cleanup" || die 'NEXT V2 cleanup module: postcheck guard отсутствует.'
  grep -Fq 'global UFW reset НЕ выполнялся' "$v2cleanup" || die 'NEXT V2 cleanup module: firewall safety marker отсутствует.'

  local network
  network="$tmp/next-installer/network-tuning-manager.sh"
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 --retry 3 \
    "$NETWORK_URL" -o "$network" || die 'Не удалось скачать Network/BBR manager.'
  [[ "$(git_blob_sha "$network")" == "$NETWORK_BLOB_SHA" ]] || die 'Network/BBR manager не прошёл Git blob SHA.'
  bash -n "$network" || die 'Network/BBR manager не прошёл bash -n.'
  grep -Fq 'sudo remnanode-next bbr-tune' "$network" || die 'Network/BBR manager: CLI hint отсутствует.'
  grep -Fq 'https://github.com/ivan-nginx/bbr3' "$network" || die 'Network/BBR manager: BBR3 source link отсутствует.'

  local tester
  tester="$tmp/next-installer/server-multitest.sh"
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 --retry 3 \
    "$TESTER_URL" -o "$tester" || die 'Не удалось скачать Server Multitest.'
  [[ "$(git_blob_sha "$tester")" == "$TESTER_BLOB_SHA" ]] || die 'Server Multitest не прошёл Git blob SHA.'
  bash -n "$tester" || die 'Server Multitest не прошёл bash -n.'
  grep -Fq 'Censorcheck — DPI' "$tester" || die 'Server Multitest: Censorcheck DPI отсутствует.'
  grep -Fq 'Geo/Media Unlock — RegionRestrictionCheck' "$tester" || die 'Server Multitest: geo/media unlock отсутствует.'
  grep -Fq 'IPQUALITY_BLOB_SHA=' "$tester" || die 'Server Multitest: IPQuality pin отсутствует.'
  grep -Fq 'YABS_BLOB_SHA=' "$tester" || die 'Server Multitest: YABS pin отсутствует.'
  grep -Fq 'YABS — disk fio only' "$tester" || die 'Server Multitest: YABS disk-only mode отсутствует.'
  grep -Fq 'run_external_script_timeout 420 "YABS' "$tester" || die 'Server Multitest: YABS timeout отсутствует.'
  grep -Fq '"$YABS_URL" "$YABS_BLOB_SHA" -ign' "$tester" || die 'Server Multitest: YABS -ign guard отсутствует.'
  ! grep -Fq '"$YABS_URL" "$YABS_BLOB_SHA" -4' "$tester" || die 'Server Multitest: ошибочный YABS -4 вернулся.'
  grep -Fq 'prepare_censorcheck(){' "$tester" || die 'Server Multitest: Censorcheck dependency guard отсутствует.'
  grep -Fq 'prepare_iperf_ru(){' "$tester" || die 'Server Multitest: iPerf dependency guard отсутствует.'
  grep -Fq 'Network Bench — HTTPS 100MB' "$tester" || die 'Server Multitest: HTTPS network bench отсутствует.'
  grep -Fq 'NETWORK_BENCH_REFERER=' "$tester" || die 'Server Multitest: Cloudflare referer guard отсутствует.'
  grep -Fq 'NETWORK_BENCH_FALLBACK_URL=' "$tester" || die 'Server Multitest: Cloudflare fallback отсутствует.'
  grep -Fq 'CPU all-thread' "$tester" || die 'Server Multitest: multi-thread CPU capacity test отсутствует.'
  grep -Fq "grep -aE 'Server[[:space:]]+Download[[:space:]]+Upload[[:space:]]+Ping|Mbps|Execution time'" "$tester" || die 'Server Multitest: iPerf report parser отсутствует.'
  grep -Fq 'NextTrace Route/MTR' "$tester" || die 'Server Multitest: NextTrace MTR отсутствует.'
  grep -Fq 'NextTrace Path MTU' "$tester" || die 'Server Multitest: NextTrace PMTU отсутствует.'
  grep -Fq 'NextTrace Globalping' "$tester" || die 'Server Multitest: NextTrace Globalping отсутствует.'
  grep -Fq 'NEXTTRACE_VERSION="v1.7.3"' "$tester" || die 'Server Multitest: NextTrace version pin отсутствует.'
  grep -Fq 'aa75440fcdee46c16d941f48f9dabee1eb4c35bea6b739b0960fcf8307088c29' "$tester" || die 'Server Multitest: NextTrace amd64 SHA256 pin отсутствует.'
  grep -Fq 'Автоматический режим: все тесты идут подряд без подтверждений.' "$tester" || die 'Server Multitest: automatic all mode отсутствует.'
  grep -Fq 'AI_REPORT.txt' "$tester" || die 'Server Multitest: AI report отсутствует.'
  grep -Fq 'summary.tsv' "$tester" || die 'Server Multitest: summary.tsv отсутствует.'
  grep -Fq 'show_latest_analysis(){' "$tester" || die 'Server Multitest: analyze command отсутствует.'
  grep -Fq '98) Анализ последнего прогона' "$tester" || die 'Server Multitest: analysis menu item отсутствует.'
  grep -Fq 'ИТОГ ПО НОДЕ' "$tester" || die 'Server Multitest: final node summary отсутствует.'
  grep -Fq 'print_colored_analysis(){' "$tester" || die 'Server Multitest: colored terminal report отсутствует.'
  ! grep -Fq 'SOURCE_REPO' "$tester" || die 'Server Multitest: stale SOURCE_REPO reference вернулся.'
  ! grep -Fq 'SOURCE_REF' "$tester" || die 'Server Multitest: stale SOURCE_REF reference вернулся.'
  grep -Fq 'АНАЛИТИКА ПОСЛЕ ТЕСТОВ' "$tester" || die 'Server Multitest: automatic inline analysis отсутствует.'
  grep -Fq 'Рабочий бюджет:' "$tester" || die 'Server Multitest: XHTTP planning budget отсутствует.'
  grep -Fq 'XHTTP ориентир:' "$tester" || die 'Server Multitest: XHTTP planning estimate отсутствует.'
  grep -Fq '"DNSBL: clean="' "$tester" || die 'Server Multitest: concise IPQuality output отсутствует.'
  grep -Fq 'server-multitest.sh machine' "$tester" || die 'Server Multitest: machine mode отсутствует.'
  grep -Fq 'remnanode.multitest.v1' "$tester" || die 'Server Multitest: machine JSON contract отсутствует.'
  grep -Fq 'MULTITEST_NO_INSTALL' "$tester" || die 'Server Multitest: no-install machine guard отсутствует.'
  ! grep -Fq 'INTERPRETATION RULE' "$tester" || die 'Server Multitest: verbose interpretation footer вернулся.'
  ! sed -n '/run_all(){/,/^}/p' "$tester" | grep -Fq 'read -r action' || die 'Server Multitest: all mode снова требует Enter.'
  if grep -Eq '(^|[^[:alnum:]])http://' "$tester"; then
    die 'Server Multitest содержит небезопасный HTTP URL.'
  fi

  local overlay_root
  overlay_root="$tmp/current-overlay"
  mkdir -p "$overlay_root/security" "$overlay_root/next-installer"
  fetch_pinned_overlay(){
    local rel="$1" expected="$2" out
    out="$overlay_root/$rel"
    mkdir -p "$(dirname "$out")"
    curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 --retry 3 \
      "https://raw.githubusercontent.com/${REPO}/${MGMT_OVERLAY_REF}/$rel" -o "$out" || die "Не удалось скачать current overlay: $rel"
    [[ "$(git_blob_sha "$out")" == "$expected" ]] || die "Current overlay Git blob SHA mismatch: $rel"
  }
  fetch_pinned_overlay protection-manager.sh "$PROTECTION_BLOB_SHA"
  fetch_pinned_overlay security/remna-security.sh "$SECURITY_SH_BLOB_SHA"
  fetch_pinned_overlay security/remna_sec.py "$SECURITY_PY_BLOB_SHA"
  fetch_pinned_overlay next-installer/telemt-manager.sh "$TELEMT_BLOB_SHA"
  fetch_pinned_overlay next-installer/telemt-legacy-rkn-adapter.sh "$TELEMT_LEGACY_BLOB_SHA"
  fetch_pinned_overlay next-installer/legacy-rebuild-manager.sh "$REBUILD_BLOB_SHA"
  bash -n "$overlay_root/protection-manager.sh"
  bash -n "$overlay_root/security/remna-security.sh"
  bash -n "$overlay_root/next-installer/telemt-manager.sh"
  bash -n "$overlay_root/next-installer/telemt-legacy-rkn-adapter.sh"
  bash -n "$overlay_root/next-installer/legacy-rebuild-manager.sh"
  python3 -m py_compile "$overlay_root/security/remna_sec.py"

  install -d -m 0700 "$NEXT_DIR" "$SECURITY_DIR" /usr/local/libexec
  install -m 0700 "$tmp/next-installer/"*.sh "$NEXT_DIR/"
  install -m 0700 "$overlay_root/protection-manager.sh" "$PROTECTION"
  install -m 0700 "$overlay_root/security/remna-security.sh" "$SECURITY_DIR/remna-security.sh"
  install -m 0600 "$overlay_root/security/remna_sec.py" "$SECURITY_DIR/remna_sec.py"
  install -m 0700 "$overlay_root/next-installer/telemt-manager.sh" "$TELEMT"
  install -m 0700 "$overlay_root/next-installer/telemt-legacy-rkn-adapter.sh" "$TELEMT_LEGACY"
  install -m 0700 "$overlay_root/next-installer/legacy-rebuild-manager.sh" "$REBUILD"

  if [[ -f "$0" ]]; then
    local current
    current="$(readlink -f "$0")"
    if [[ "$current" != "$SELF" ]]; then
      install -m 0700 "$current" "$SELF"
    fi
    ln -sfn "$SELF" "$CLI"
  fi
  ok "NEXT source синхронизирован → $NEXT_DIR"
  rm -rf "$tmp"
}

release_status(){
  if [[ ! -s "$RELEASE_MARKER" ]]; then
    printf '{"schema":"remnanode.release.v1","installed":false,"release_sha":null,"identity_ok":false,"image_ok":false}\n'
    return 0
  fi
  local current_identity current_image
  current_identity="$(managed_identity_digest 2>/dev/null | sed -n '1p' || true)"
  current_image="$(managed_running_image_digest 2>/dev/null | sed -n '1p' || true)"
  python3 - "$RELEASE_MARKER" "$current_identity" "$current_image" <<'PY'
import json, re, sys
from pathlib import Path
p=Path(sys.argv[1])
current_identity=sys.argv[2]
current_image=sys.argv[3]
try:
    d=json.loads(p.read_text(encoding="utf-8"))
except Exception:
    print('{"schema":"remnanode.release.v1","installed":false,"release_sha":null,"identity_ok":false,"image_ok":false,"error":"invalid_marker"}')
    raise SystemExit(0)
sha=str(d.get("release_sha") or "")
identity=str(d.get("identity_digest") or "")
image=str(d.get("node_image_digest") or "")
if not re.fullmatch(r"[0-9a-f]{40}", sha):
    print('{"schema":"remnanode.release.v1","installed":false,"release_sha":null,"identity_ok":false,"image_ok":false,"error":"invalid_sha"}')
    raise SystemExit(0)
identity_valid=bool(re.fullmatch(r"[0-9a-f]{64}", identity))
image_valid=bool(re.fullmatch(r"sha256:[0-9a-f]{64}", image))
current_identity_valid=bool(re.fullmatch(r"[0-9a-f]{64}", current_identity))
current_image_valid=bool(re.fullmatch(r"sha256:[0-9a-f]{64}", current_image))
print(json.dumps({
    "schema":"remnanode.release.v1",
    "installed":True,
    "release_sha":sha,
    "installed_at":d.get("installed_at"),
    "method":d.get("method"),
    "identity_digest":identity if identity_valid else None,
    "identity_ok":bool(identity_valid and current_identity_valid and identity == current_identity),
    "node_image_digest":image if image_valid else None,
    "image_ok":bool(image_valid and current_image_valid and image == current_image),
    "marker_integrity_ok":bool(identity_valid and image_valid),
}, ensure_ascii=False, separators=(",",":")))
PY
}

write_release_marker(){
  local sha="$1" identity_digest="$2" method="${3:-in-place}"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die 'AINOC release SHA invalid.'
  [[ "$identity_digest" =~ ^[0-9a-f]{64}$ ]] || die 'AINOC identity digest invalid.'
  [[ "$NODE_IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die 'AINOC node image digest invalid.'
  python3 - "$RELEASE_MARKER" "$sha" "$identity_digest" "$NODE_IMAGE_DIGEST" "$method" <<'PY'
import json, os, sys, tempfile
from datetime import datetime, timezone
from pathlib import Path

target=Path(sys.argv[1])
payload={
    "schema":"remnanode.release.v1",
    "release_sha":sys.argv[2],
    "identity_digest":sys.argv[3],
    "node_image_digest":sys.argv[4],
    "installed_at":datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "method":sys.argv[5],
}
target.parent.mkdir(parents=True, exist_ok=True)
fd,tmp=tempfile.mkstemp(prefix=".ainoc-release.",dir=str(target.parent))
try:
    os.fchmod(fd,0o600)
    with os.fdopen(fd,"w",encoding="utf-8") as fh:
        fh.write(json.dumps(payload,ensure_ascii=False,separators=(",",":"))+"\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp,target)
    dfd=os.open(str(target.parent),os.O_RDONLY | getattr(os,"O_DIRECTORY",0))
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
except Exception:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise
PY
}

managed_identity_manifest(){
  local out="$1"
  python3 - "$out" "$APP_DIR" "$TELEMT_CONFIG_FILE" "$TELEMT_PANEL_CONFIG_FILE" <<'PY'
import hashlib, json, sys
from pathlib import Path
out=Path(sys.argv[1])
app=Path(sys.argv[2])
telemt=Path(sys.argv[3])
telemt_panel=Path(sys.argv[4])
fixed=[
    app/".env", app/".node_domain", app/".panel_ip", app/".transport",
    app/".camouflage_mode", app/"reality.env", app/".reality_sni",
    app/".reality_target", app/".xhttp_path", app/"nginx.conf",
    app/"xhttp-signature.json", telemt, telemt_panel,
]
paths=list(fixed)
profiles=app/"remnawave-profiles"
if profiles.is_dir():
    paths.extend(sorted(
        p for p in profiles.iterdir()
        if p.is_file() and (
            p.suffix == ".json"
            or (p.name.startswith("host-") and p.suffix == ".txt")
        )
    ))
items=[]
for path in paths:
    if path.is_file():
        data=path.read_bytes()
        items.append({"path":str(path),"state":"file","sha256":hashlib.sha256(data).hexdigest()})
    else:
        items.append({"path":str(path),"state":"missing","sha256":None})
raw=json.dumps({"schema":"remnanode.identity.v1","files":items},ensure_ascii=False,sort_keys=True,separators=(",",":"))
out.write_text(raw+"\n",encoding="utf-8")
PY
  chmod 0600 "$out"
}

managed_identity_digest(){
  local tmp digest
  install -d -m 0700 "$MANAGED_UPDATE_RUNTIME_DIR"
  tmp="$(mktemp "$MANAGED_UPDATE_RUNTIME_DIR/remnanode-identity.XXXXXX")"
  managed_identity_manifest "$tmp"
  digest="$(sha256sum "$tmp" | awk '{print $1}')"
  rm -f "$tmp"
  printf '%s\n' "$digest"
}

managed_running_image_digest(){
  command -v docker >/dev/null 2>&1 || return 1
  [[ "$NODE_IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  local cid image_id image_ref digests expected
  cid="$(cd "$APP_DIR" && docker compose ps -q remnanode 2>/dev/null || true)"
  [[ -n "$cid" ]] || return 1
  image_id="$(docker inspect "$cid" --format '{{.Image}}' 2>/dev/null || true)"
  image_ref="$(docker inspect "$cid" --format '{{.Config.Image}}' 2>/dev/null || true)"
  [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  if [[ "$image_ref" == "$NODE_IMAGE" ]]; then
    printf '%s\n' "$NODE_IMAGE_DIGEST"
    return 0
  fi
  expected="ghcr.io/remnawave/node@$NODE_IMAGE_DIGEST"
  digests="$(docker image inspect "$image_id" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null || true)"
  if grep -Fqx "$expected" <<<"$digests"; then
    printf '%s\n' "$NODE_IMAGE_DIGEST"
  else
    printf '%s\n' "$image_id"
  fi
}

managed_update_backup(){
  local stamp dir rootfs src
  stamp="$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "$MANAGED_UPDATE_BACKUP_ROOT"
  dir="$(mktemp -d "$MANAGED_UPDATE_BACKUP_ROOT/$stamp.XXXXXX")"
  chmod 0700 "$dir"
  rootfs="$dir/rootfs"
  install -d -m 0700 "$rootfs"
  local dst
  for src in "$SELF" "$NEXT_DIR" "$PROTECTION" "$SECURITY_DIR" "$APP_DIR/docker-compose.yml" "$RELEASE_MARKER"; do
    [[ -e "$src" || -L "$src" ]] || continue
    dst="$rootfs/${src#/}"
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst" || die "managed-update backup failed: $src"
  done
  managed_identity_manifest "$dir/identity.before.json"
  python3 - "$dir/identity.before.json" "$rootfs" <<'PY'
import json, shutil, sys
from pathlib import Path
manifest=Path(sys.argv[1])
rootfs=Path(sys.argv[2])
data=json.loads(manifest.read_text(encoding="utf-8"))
for item in data.get("files", []):
    if item.get("state") != "file":
        continue
    src=Path(str(item["path"]))
    dst=rootfs / str(src).lstrip("/")
    expected=str(item.get("sha256") or "")
    if not src.is_file():
        raise SystemExit(f"identity source disappeared during backup: {src}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    actual=__import__("hashlib").sha256(dst.read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f"identity changed during backup: {src}")
PY
  chmod -R go-rwx "$dir"
  printf '%s\n' "$dir"
}

managed_update_restore_identity(){
  local dir="$1" rootfs="$1/rootfs" manifest="$1/identity.before.json"
  [[ -s "$manifest" ]] || { warn 'Managed update rollback: identity manifest missing.'; return 1; }
  python3 - "$manifest" "$rootfs" "$APP_DIR" <<'PY'
import json, shutil, sys
from pathlib import Path
manifest=Path(sys.argv[1])
rootfs=Path(sys.argv[2])
app=Path(sys.argv[3])
data=json.loads(manifest.read_text(encoding="utf-8"))
items=data.get("files", [])
profiles=app/"remnawave-profiles"
if profiles.is_dir():
    for p in profiles.iterdir():
        if p.is_file() and (p.suffix == ".json" or (p.name.startswith("host-") and p.suffix == ".txt")):
            p.unlink()
for item in items:
    dst=Path(str(item["path"]))
    state=item.get("state")
    if state == "missing":
        try:
            dst.unlink()
        except FileNotFoundError:
            pass
        continue
    if state != "file":
        raise SystemExit(f"unsupported identity state for {dst}: {state}")
    src=rootfs / str(dst).lstrip("/")
    if not src.is_file():
        raise SystemExit(f"identity backup missing: {src}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
PY
}

managed_update_restore_code(){
  local dir="$1" rootfs="$1/rootfs"
  warn "Managed update rollback: восстанавливаю launcher/scripts/compose из $dir"
  if [[ -d "$rootfs/opt/remnanode/next-installer" ]]; then
    rm -rf "$NEXT_DIR"
    mkdir -p "$(dirname "$NEXT_DIR")"
    cp -a "$rootfs/opt/remnanode/next-installer" "$NEXT_DIR"
  fi
  if [[ -e "$rootfs/usr/local/libexec/remnanode-next.sh" ]]; then
    install -m 0700 "$rootfs/usr/local/libexec/remnanode-next.sh" "$SELF"
    ln -sfn "$SELF" "$CLI"
  fi
  if [[ -e "$rootfs/opt/remnanode/protection-manager.sh" ]]; then
    install -m 0700 "$rootfs/opt/remnanode/protection-manager.sh" "$PROTECTION"
  fi
  if [[ -d "$rootfs/opt/remnanode/security" ]]; then
    rm -rf "$SECURITY_DIR"
    cp -a "$rootfs/opt/remnanode/security" "$SECURITY_DIR"
  fi
  if [[ -e "$rootfs/opt/remnanode/docker-compose.yml" ]]; then
    cp -a "$rootfs/opt/remnanode/docker-compose.yml" "$APP_DIR/docker-compose.yml"
  fi
  if [[ -e "$rootfs/opt/remnanode/.ainoc-release.json" ]]; then
    cp -a "$rootfs/opt/remnanode/.ainoc-release.json" "$RELEASE_MARKER"
  else
    rm -f "$RELEASE_MARKER"
  fi
}

managed_update_rollback(){
  local dir="$1" expected_image="$2" current expected_identity restored_identity i
  managed_update_restore_code "$dir"
  managed_update_restore_identity "$dir" || return 1
  expected_identity="$(sha256sum "$dir/identity.before.json" | awk '{print $1}')"
  restored_identity="$(managed_identity_digest 2>/dev/null || true)"
  if [[ "$restored_identity" != "$expected_identity" ]]; then
    warn "Managed update rollback identity mismatch: expected=$expected_identity got=$restored_identity"
    return 1
  fi

  current="$(managed_running_image_digest 2>/dev/null || true)"
  if [[ "$current" == "$expected_image" ]]; then
    ok "Managed update rollback identity + image verified."
    return 0
  fi

  ( cd "$APP_DIR" && docker compose up -d --no-deps remnanode >/dev/null 2>&1 ) || {
    warn 'Managed update rollback: docker compose up failed.'
    return 1
  }
  for i in $(seq 1 30); do
    current="$(managed_running_image_digest 2>/dev/null || true)"
    if [[ "$current" == "$expected_image" ]]; then
      ok "Managed update rollback identity + image verified."
      return 0
    fi
    sleep 2
  done
  warn "Managed update rollback image mismatch: expected=${expected_image:0:19}… got=${current:0:19}…"
  return 1
}

managed_patch_node_image(){
  local compose="$APP_DIR/docker-compose.yml" tmp current after i
  [[ -s "$compose" ]] || die 'managed-update: docker-compose.yml missing.'
  tmp="$(mktemp "$APP_DIR/.docker-compose.XXXXXX")"
  python3 - "$compose" "$tmp" "$NODE_IMAGE" <<'PY'
import re, sys
from pathlib import Path
src=Path(sys.argv[1]); dst=Path(sys.argv[2]); image=sys.argv[3]
text=src.read_text(encoding="utf-8")
pat=re.compile(r'(?m)^(\s*image:\s*)ghcr\.io/remnawave/node:[^\s#]+\s*$')
new,n=pat.subn(lambda m:m.group(1)+image,text,count=1)
if n != 1:
    raise SystemExit("expected exactly one remnanode image line")
dst.write_text(new,encoding="utf-8")
PY
  chmod --reference="$compose" "$tmp" 2>/dev/null || chmod 0600 "$tmp"
  mv -f "$tmp" "$compose"
  ( cd "$APP_DIR" && docker compose config -q ) || return 1

  current="$(managed_running_image_digest)"
  if [[ "$current" == "$NODE_IMAGE_DIGEST" ]]; then
    ok "Remnanode image уже соответствует release digest: ${NODE_IMAGE_DIGEST:0:19}…"
    return 0
  fi
  docker pull "$NODE_IMAGE" >/dev/null || return 1
  ( cd "$APP_DIR" && docker compose up -d --no-deps remnanode ) || return 1
  for i in $(seq 1 30); do
    after="$(managed_running_image_digest 2>/dev/null || true)"
    [[ "$after" == "$NODE_IMAGE_DIGEST" ]] && return 0
    sleep 2
  done
  return 1
}

managed_update_postcheck(){
  local before_telemt="$1" before_panel="$2" node_port
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode || return 1
  node_port="$(awk -F= '$1=="NODE_PORT"{print $2; exit}' "$APP_DIR/.env" 2>/dev/null | tr -d '[:space:]')"
  [[ "$node_port" =~ ^[0-9]+$ ]] || node_port=2222
  ss -lntup 2>/dev/null | grep -q ":${node_port}[[:space:]]" || return 1
  if [[ "$before_telemt" == active ]]; then systemctl is-active --quiet telemt.service || return 1; fi
  if [[ "$before_panel" == active ]]; then systemctl is-active --quiet telemt-panel.service || return 1; fi
  [[ "$(managed_running_image_digest)" == "$NODE_IMAGE_DIGEST" ]] || return 1
}

managed_update_is_current(){
  local release_sha="$1" status
  status="$(release_status 2>/dev/null || true)"
  python3 - "$release_sha" "$status" <<'PY'
import json, sys
target=sys.argv[1]
try:
    d=json.loads(sys.argv[2])
except Exception:
    raise SystemExit(1)
ok=(
    d.get("schema") == "remnanode.release.v1"
    and d.get("installed") is True
    and d.get("release_sha") == target
    and d.get("identity_ok") is True
    and d.get("image_ok") is True
    and d.get("marker_integrity_ok") is True
)
raise SystemExit(0 if ok else 1)
PY
}

managed_update_prune_backups(){
  local keep="${MANAGED_UPDATE_KEEP_BACKUPS:-5}"
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=5
  (( keep >= 1 )) || keep=5
  python3 - "$MANAGED_UPDATE_BACKUP_ROOT" "$keep" <<'PY'
import re, shutil, sys
from pathlib import Path
root=Path(sys.argv[1])
keep=int(sys.argv[2])
if not root.is_dir():
    raise SystemExit(0)
pat=re.compile(r"^\d{8}-\d{6}\.[A-Za-z0-9]+$")
dirs=[p for p in root.iterdir() if p.is_dir() and pat.fullmatch(p.name)]
dirs.sort(key=lambda p:p.stat().st_mtime, reverse=True)
for p in dirs[keep:]:
    shutil.rmtree(p)
PY
}

run_managed_update(){
  local release_sha backup before_identity backup_identity after_identity before_telemt before_panel before_image lock_fd
  release_sha="${AINOC_RELEASE_SHA:-}"
  [[ "$release_sha" =~ ^[0-9a-f]{40}$ ]] || die 'managed-update требует trusted AINOC_RELEASE_SHA (40 hex).'

  command -v flock >/dev/null 2>&1 || die 'managed-update: flock отсутствует.'
  install -d -m 0700 "$MANAGED_UPDATE_RUNTIME_DIR"
  exec {lock_fd}>"$MANAGED_UPDATE_RUNTIME_DIR/remnanode-managed-update.lock"
  flock -n "$lock_fd" || die 'managed-update: другая операция обновления уже выполняется.'

  if managed_update_is_current "$release_sha"; then
    ok "AINOC release уже установлен и identity/image verified: ${release_sha:0:12}"
    flock -u "$lock_fd" || true
    eval "exec ${lock_fd}>&-"
    return 0
  fi

  [[ -s "$APP_DIR/.env" ]] || die 'managed-update: RemnaNode .env отсутствует.'
  [[ -s "$APP_DIR/.node_domain" ]] || die 'managed-update: node domain marker отсутствует.'
  [[ -s "$APP_DIR/.transport" ]] || die 'managed-update: transport marker отсутствует.'

  before_identity="$(managed_identity_digest)"
  before_image="$(managed_running_image_digest)" || die 'managed-update: current Remnanode image cannot be identified safely.'
  before_telemt="$(systemctl is-active telemt.service 2>/dev/null || true)"
  before_panel="$(systemctl is-active telemt-panel.service 2>/dev/null || true)"
  backup="$(managed_update_backup)"
  backup_identity="$(sha256sum "$backup/identity.before.json" | awk '{print $1}')"
  [[ "$backup_identity" == "$before_identity" ]] || die 'managed-update: identity changed during preflight/backup; update refused before mutation.'
  ok "managed-update backup verified: $backup"

  if ! AINOC_INPLACE_UPDATE=1 sync_next_sources; then
    if ! managed_update_rollback "$backup" "$before_image"; then
      die 'managed-update: source sync failed AND verified rollback failed.'
    fi
    die 'managed-update: source sync failed; verified identity+image rollback applied.'
  fi
  if ! managed_patch_node_image; then
    if ! managed_update_rollback "$backup" "$before_image"; then
      die 'managed-update: image update failed AND identity+image rollback verification failed.'
    fi
    die 'managed-update: image update failed; verified identity+image rollback applied.'
  fi

  after_identity="$(managed_identity_digest)"
  if [[ "$after_identity" != "$before_identity" ]]; then
    if ! managed_update_rollback "$backup" "$before_image"; then
      die 'managed-update: CONNECTION IDENTITY DRIFT detected; identity+image rollback verification failed.'
    fi
    die 'managed-update: CONNECTION IDENTITY DRIFT detected; verified identity+image rollback applied, release marker NOT written.'
  fi
  if ! managed_update_postcheck "$before_telemt" "$before_panel"; then
    if ! managed_update_rollback "$backup" "$before_image"; then
      die 'managed-update: postcheck failed AND identity+image rollback verification failed.'
    fi
    die 'managed-update: postcheck failed; verified identity+image rollback applied.'
  fi

  write_release_marker "$release_sha" "$after_identity" in-place
  ok "AINOC in-place release установлен без изменения connection identity: ${release_sha:0:12}"
  ok "Rollback point: $backup"
  managed_update_prune_backups || warn 'managed-update: не удалось удалить старые recovery backups.'
  flock -u "$lock_fd" || true
  eval "exec ${lock_fd}>&-"
}

legacy_call(){
  local fn="$1"
  [[ -x "$LEGACY" ]] || die "Не найден $LEGACY"
  bash -Eeuo pipefail -c '
    legacy="$1"; fn="$2"
    source <(sed -e "\$d" "$legacy")
    check_os
    detect_arch
    "$fn"
  ' "$LEGACY" "$LEGACY" "$fn"
}

base_install(){
  sync_next_sources
  if [[ -s "$APP_DIR/docker-compose.yml" ]] && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
    warn 'Базовая Remnanode уже существует — первоначальную установку не повторяю.'
    return 0
  fi
  legacy_call run_initial_setup
}

post_transport(){
  local transport=""
  [[ -r "$APP_DIR/.transport" ]] && transport="$(tr -d '[:space:]' < "$APP_DIR/.transport")"
  case "$transport" in
    xhttp|combined)
      "$SIGNATURE" apply || warn 'XHTTP signature не применена; профиль оставлен в предыдущем рабочем состоянии.'
      ;;
  esac
  case "$transport" in
    hysteria|combined)
      "$GUARDS" restore-hysteria || warn 'Проверь cert mount Hysteria2.'
      ;;
  esac
}

transport_menu(){
  sync_next_sources
  [[ -s "$APP_DIR/docker-compose.yml" ]] || die 'Сначала установи базовую ноду.'
  "$TRANSPORT"
  post_transport
}

copy_profile_menu(){
  sync_next_sources
  local choice file="" host1="" host2=""

  print_host_settings(){
    local label="$1" host="$2"
    [[ -s "$host" ]] || { warn "Host settings ещё не созданы: $host"; return 1; }
    echo
    echo "================ $label — КОПИРУЙ В REMNAWAVE HOST ================"
    cat "$host"
    echo "================ КОНЕЦ $label ======================================"
  }

  while true; do
    cat <<'MENU'

────────────────────────────────────────────────────────────
REMNAWAVE — CONFIG PROFILE + НАСТРОЙКИ HOST
────────────────────────────────────────────────────────────
 [1] XHTTP + REALITY         (TCP/443)
     → JSON Config Profile + HOST XHTTP

 [2] RAW + REALITY           (TCP/443)
     → JSON Config Profile + HOST RAW

 [3] Hysteria2 + TLS         (UDP/443)
     → JSON Config Profile + HOST HYSTERIA2

 [4] XHTTP + Hysteria2       (TCP/443 + UDP/443)
     → JSON Config Profile + HOST XHTTP + HOST HYSTERIA2

 [5] ТОЛЬКО HOST XHTTP
 [6] ТОЛЬКО HOST HYSTERIA2
 [7] ТОЛЬКО HOST RAW

 [0] Назад
────────────────────────────────────────────────────────────
MENU
    printf 'Выбор: '; read -r choice < "$TTY" || true
    file=""; host1=""; host2=""

    case "$choice" in
      1)
        file="$APP_DIR/remnawave-profiles/xhttp-reality.json"
        host1="$APP_DIR/remnawave-profiles/host-xhttp.txt"
        ;;
      2)
        file="$APP_DIR/remnawave-profiles/raw-reality.json"
        host1="$APP_DIR/remnawave-profiles/host-raw.txt"
        ;;
      3)
        file="$APP_DIR/remnawave-profiles/hysteria2-tls.json"
        host1="$APP_DIR/remnawave-profiles/host-hysteria2.txt"
        ;;
      4)
        file="$APP_DIR/remnawave-profiles/xhttp-hysteria2.json"
        host1="$APP_DIR/remnawave-profiles/host-xhttp.txt"
        host2="$APP_DIR/remnawave-profiles/host-hysteria2.txt"
        ;;
      5)
        print_host_settings "HOST XHTTP" "$APP_DIR/remnawave-profiles/host-xhttp.txt" || true
        pause
        continue
        ;;
      6)
        print_host_settings "HOST HYSTERIA2" "$APP_DIR/remnawave-profiles/host-hysteria2.txt" || true
        pause
        continue
        ;;
      7)
        print_host_settings "HOST RAW" "$APP_DIR/remnawave-profiles/host-raw.txt" || true
        pause
        continue
        ;;
      0|'') return 0 ;;
      *) warn 'Неверный пункт.'; continue ;;
    esac

    if [[ ! -s "$file" ]]; then
      warn "Профиль ещё не создан: $file"
      warn 'Сначала открой пункт «Транспорт / профили».'
      pause
      continue
    fi

    echo
    echo '================ CONFIG PROFILE — КОПИРУЙ JSON ======================'
    warn 'JSON может содержать REALITY privateKey. Не публикуй его.'
    cat "$file"
    echo
    echo '================ КОНЕЦ CONFIG PROFILE ==============================='

    if [[ -n "$host1" ]]; then
      case "$host1" in
        *host-xhttp.txt) print_host_settings "HOST XHTTP" "$host1" || true ;;
        *host-hysteria2.txt) print_host_settings "HOST HYSTERIA2" "$host1" || true ;;
        *host-raw.txt) print_host_settings "HOST RAW" "$host1" || true ;;
      esac
    fi
    if [[ -n "$host2" ]]; then
      case "$host2" in
        *host-xhttp.txt) print_host_settings "HOST XHTTP" "$host2" || true ;;
        *host-hysteria2.txt) print_host_settings "HOST HYSTERIA2" "$host2" || true ;;
        *host-raw.txt) print_host_settings "HOST RAW" "$host2" || true ;;
      esac
    fi

    pause
  done
}

signature_menu(){
  sync_next_sources
  local c
  while true; do
    cat <<'MENU'

XHTTP signature
 [1] Применить / создать стабильную per-node signature
 [2] Показать сохранённую signature
 [3] Снять signature с XHTTP profile
 [0] Назад
MENU
    printf 'Выбор: '; read -r c < "$TTY" || true
    case "$c" in
      1) "$SIGNATURE" apply; pause ;;
      2) "$SIGNATURE" show; pause ;;
      3) "$SIGNATURE" revert; pause ;;
      0|'') return 0 ;;
      *) warn 'Неверный пункт.' ;;
    esac
  done
}

runtime_menu(){
  sync_next_sources
  local c
  while true; do
    cat <<'MENU'

Runtime guards / repair
 [1] Восстановить Hysteria2 cert mount
 [2] Восстановить RKN guard
 [3] Синхронизировать RKN self-heal watcher
 [4] Удалить RKN self-heal watcher
 [0] Назад
MENU
    printf 'Выбор: '; read -r c < "$TTY" || true
    case "$c" in
      1) "$GUARDS" restore-hysteria; pause ;;
      2) "$GUARDS" restore-rkn; pause ;;
      3) "$GUARDS" sync-rkn-watch; pause ;;
      4) "$GUARDS" remove-rkn-watch; pause ;;
      0|'') return 0 ;;
      *) warn 'Неверный пункт.' ;;
    esac
  done
}

base_manage_menu(){
  sync_next_sources
  local c fn
  while true; do
    cat <<'MENU'

Базовое управление Remnanode
 [1] Первоначальная настройка
 [2] Смена домена / SSL
 [3] Обновить Xray/rw-core
 [4] Изменить IP панели
 [5] Управление IPv6
 [6] Диагностика и логи
 [7] Клиентские порты Xray/UFW
 [8] Сменить маскировочный шаблон
 [9] Мульти-тесты сервера
 [0] Назад

Удаление из legacy-меню намеренно не вынесено сюда: старый uninstall делает global UFW reset.
MENU
    printf 'Выбор: '; read -r c < "$TTY" || true
    case "$c" in
      1) fn=run_initial_setup ;;
      2) fn=change_domain_and_ssl ;;
      3) fn=update_xray_core_only ;;
      4) fn=change_panel_ip ;;
      5) fn=manage_ipv6_menu ;;
      6) fn=diagnose_and_logs ;;
      7) fn=manage_xray_ports ;;
      8) fn=change_decoy_template_menu ;;
      9) "$TESTER" menu; continue ;;
      0|'') return 0 ;;
      *) warn 'Неверный пункт.'; continue ;;
    esac
    legacy_call "$fn"
  done
}

show_status(){
  sync_next_sources
  echo '================ REMNANODE NEXT STATUS ================'
  printf 'Transport : %s\n' "$(cat "$APP_DIR/.transport" 2>/dev/null || echo 'не выбран')"
  printf 'Domain    : %s\n' "$(cat "$APP_DIR/.node_domain" 2>/dev/null || echo 'не задан')"
  printf 'Node      : '
  if command -v docker >/dev/null 2>&1; then docker ps --filter name='^/remnanode$' --format '{{.Status}}' 2>/dev/null | head -1 || true; else echo 'docker отсутствует'; fi
  printf 'Nginx     : '
  if command -v docker >/dev/null 2>&1; then docker ps --filter name='^/remnawave-nginx$' --format '{{.Status}}' 2>/dev/null | head -1 || true; else echo 'docker отсутствует'; fi
  echo 'Listeners :'
  ss -lntup 2>/dev/null | grep -E '(:443|:2222)[[:space:]]' || true
  printf 'Network   : %s / %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  echo 'Profiles  :'
  find "$APP_DIR/remnawave-profiles" -maxdepth 1 -type f -name '*.json' -printf '  %f\n' 2>/dev/null | sort || true
  if [[ -x "$RKN" ]]; then
    echo 'RKN       :'
    "$RKN" status || true
  fi
}

hysteria_diag(){
  local domain runtime_tmp="" runtime_ok=0 drift=0
  domain="$(cat "$APP_DIR/.node_domain" 2>/dev/null || true)"

  echo '================ HYSTERIA2 DIAGNOSTICS ================'
  printf 'Domain      : %s\n' "${domain:-unknown}"
  echo 'UDP/443 listener:'
  ss -lunp 2>/dev/null | grep -E '(:443[[:space:]]|:443$)' || echo '  НЕТ UDP/443 LISTENER'

  echo
  echo 'DNS addresses:'
  if [[ -n "$domain" ]]; then
    getent ahosts "$domain" 2>/dev/null | awk '!seen[$1]++{print "  " $1}' || true
  fi

  echo
  echo 'RKN UDP/443 DROP rule + counters:'
  if command -v iptables >/dev/null 2>&1 && iptables -nL REMNA_RKN_SCANNERS >/dev/null 2>&1; then
    iptables -nvxL REMNA_RKN_SCANNERS --line-numbers 2>/dev/null | grep -E 'udp.*dpt:443|udp.*443' || echo '  UDP/443 DROP rule не найден'
  else
    echo '  REMNA_RKN_SCANNERS chain не найден'
  fi

  echo
  echo 'Effective Remnawave runtime:'
  if ! command -v jq >/dev/null 2>&1; then
    echo '  [WARN] jq отсутствует — runtime drift check пропущен'
  elif ! command -v docker >/dev/null 2>&1 || ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
    echo '  [WARN] remnanode не запущен — runtime drift check пропущен'
  else
    runtime_tmp="$(mktemp)"
    if docker exec remnanode cli --dump-config-raw >"$runtime_tmp" 2>/dev/null; then
      runtime_ok=1
      local hy_count clients_count auth_bad
      hy_count="$(jq '[.inbounds[]? | select(.protocol=="hysteria")] | length' "$runtime_tmp" 2>/dev/null || echo 0)"
      clients_count="$(jq '[.inbounds[]? | select(.protocol=="hysteria") | (.settings.clients // [])[]?] | length' "$runtime_tmp" 2>/dev/null || echo 0)"
      auth_bad="$(jq '[.inbounds[]? | select(.protocol=="hysteria") | (.settings.clients // [])[]? | select((.auth // "") != (.id // ""))] | length' "$runtime_tmp" 2>/dev/null || echo 0)"
      printf '  Hysteria inbounds : %s\n' "$hy_count"
      printf '  Runtime clients   : %s\n' "$clients_count"
      printf '  auth != id        : %s\n' "$auth_bad"

      check_runtime(){
        local label="$1" filter="$2"
        if jq -e "$filter" "$runtime_tmp" >/dev/null 2>&1; then
          printf '  [PASS] %s\n' "$label"
        else
          printf '  [FAIL] %s\n' "$label"
          drift=1
        fi
      }

      check_runtime 'ровно один Hysteria inbound' '[.inbounds[]? | select(.protocol=="hysteria")] | length == 1'
      check_runtime 'version=2' '[.inbounds[]? | select(.protocol=="hysteria")][0].settings.version == 2'
      check_runtime 'network=hysteria + security=tls' '([.inbounds[]? | select(.protocol=="hysteria")][0].streamSettings.network == "hysteria") and ([.inbounds[]? | select(.protocol=="hysteria")][0].streamSettings.security == "tls")'
      check_runtime 'sniffing http,tls,quic + routeOnly' '([.inbounds[]? | select(.protocol=="hysteria")][0].sniffing.enabled == true) and ([.inbounds[]? | select(.protocol=="hysteria")][0].sniffing.routeOnly == true) and (([.inbounds[]? | select(.protocol=="hysteria")][0].sniffing.destOverride // []) | index("http") != null) and (([.inbounds[]? | select(.protocol=="hysteria")][0].sniffing.destOverride // []) | index("tls") != null) and (([.inbounds[]? | select(.protocol=="hysteria")][0].sniffing.destOverride // []) | index("quic") != null)'
      check_runtime 'server-side masquerade отсутствует' '([.inbounds[]? | select(.protocol=="hysteria")][0].streamSettings.hysteriaSettings | has("masquerade")) | not'
      check_runtime 'server-side finalmask отсутствует' '([.inbounds[]? | select(.protocol=="hysteria")][0].streamSettings | has("finalmask")) | not'
      check_runtime 'TLS SNI совпадает с node domain' "[.inbounds[]? | select(.protocol==\"hysteria\")][0].streamSettings.tlsSettings.serverName == \"$domain\""
      check_runtime 'TLS 1.2..1.3' '([.inbounds[]? | select(.protocol=="hysteria")][0].streamSettings.tlsSettings.minVersion == "1.2") and ([.inbounds[]? | select(.protocol=="hysteria")][0].streamSettings.tlsSettings.maxVersion == "1.3")'
      check_runtime 'rejectUnknownSni=true' '[.inbounds[]? | select(.protocol=="hysteria")][0].streamSettings.tlsSettings.rejectUnknownSni == true'
      check_runtime 'enableSessionResumption=true' '[.inbounds[]? | select(.protocol=="hysteria")][0].streamSettings.tlsSettings.enableSessionResumption == true'
      check_runtime 'ALPN h3' '([.inbounds[]? | select(.protocol=="hysteria")][0].streamSettings.tlsSettings.alpn // []) | index("h3") != null'
      if [[ "$auth_bad" != "0" ]]; then
        printf '  [FAIL] runtime auth отличается от client id у %s пользователей\n' "$auth_bad"
        drift=1
      else
        echo '  [PASS] runtime auth совпадает с client id'
      fi

      local expected_profile expected_norm runtime_norm
      expected_profile="$APP_DIR/remnawave-profiles/hysteria2-tls.json"
      if [[ -s "$expected_profile" ]]; then
        expected_norm="$(mktemp)"
        runtime_norm="$(mktemp)"
        jq -S '
          [.inbounds[]? | select(.protocol=="hysteria")][0]
          | .settings.clients = []
          | del(.tag)
          | if .sniffing.metadataOnly == false then del(.sniffing.metadataOnly) else . end
        ' "$expected_profile" >"$expected_norm" 2>/dev/null || true
        jq -S '
          [.inbounds[]? | select(.protocol=="hysteria")][0]
          | .settings.clients = []
          | del(.tag)
          | if .sniffing.metadataOnly == false then del(.sniffing.metadataOnly) else . end
        ' "$runtime_tmp" >"$runtime_norm" 2>/dev/null || true
        if [[ -s "$expected_norm" && -s "$runtime_norm" ]] && cmp -s "$expected_norm" "$runtime_norm"; then
          echo '  [PASS] runtime семантически совпадает с локальным hysteria2-tls.json'
        else
          echo '  [FAIL] runtime отличается от локального hysteria2-tls.json'
          echo '         Сравнение игнорирует только tag, динамические clients и metadataOnly=false.'
          drift=1
        fi
        rm -f "$expected_norm" "$runtime_norm"
      else
        echo '  [WARN] локальный hysteria2-tls.json отсутствует — semantic compare пропущен'
      fi
    else
      echo '  [WARN] cli --dump-config-raw не вернул конфигурацию'
    fi
    rm -f "$runtime_tmp"
  fi

  echo
  if (( runtime_ok )) && (( drift )); then
    echo '[FAIL] HYSTERIA2 RUNTIME DRIFT: активный Config Profile Remnawave не соответствует NEXT.'
    echo 'Исправь Hysteria Config Profile/Host в панели; ноду переустанавливать не нужно.'
    echo 'Host guard: Vless Route ID = ПУСТО / DEFAULT; Final Mask = ПУСТО / DEFAULT.'
    echo '========================================================='
    return 1
  elif (( runtime_ok )); then
    echo '[PASS] HYSTERIA2 RUNTIME MATCH: активный Remnawave profile соответствует NEXT.'
  else
    echo '[WARN] Runtime profile не удалось проверить; сетевые проверки выше остаются валидными.'
  fi

  echo 'Подсказка: если runtime PASS, UDP/443 слушает, но RKN DROP counter растёт при попытке через LTE,'
  echo 'проблема уже в firewall/RKN path / IP мобильного оператора.'
  echo '========================================================='
}

backup_current(){
  [[ -d "$APP_DIR" ]] || return 0
  local stamp dst rel paths=()
  stamp="$(date +%Y%m%d-%H%M%S)"
  dst="/root/remnanode-next-backup-${stamp}.tar.gz"
  for rel in \
    opt/remnanode/.env \
    opt/remnanode/.node_domain \
    opt/remnanode/.node_name \
    opt/remnanode/.panel_ip \
    opt/remnanode/.protocol \
    opt/remnanode/.transport \
    opt/remnanode/.camouflage_mode \
    opt/remnanode/.reality_sni \
    opt/remnanode/.reality_target \
    opt/remnanode/.xhttp_path \
    opt/remnanode/reality.env \
    opt/remnanode/xhttp-signature.json \
    opt/remnanode/docker-compose.yml \
    opt/remnanode/nginx.conf \
    opt/remnanode/certs \
    opt/remnanode/remnawave-profiles \
    opt/remna-protection \
    var/log/remna-protection \
    etc/telemt \
    etc/telemt-panel \
    var/lib/telemt-panel \
    etc/systemd/system/remna-protection.service \
    etc/systemd/system/remna-protection-update.service \
    etc/systemd/system/remna-protection-update.timer
  do
    [[ -e "/$rel" ]] && paths+=("$rel")
  done
  ((${#paths[@]})) || return 0
  tar -C / -czf "$dst" "${paths[@]}"
  chmod 0600 "$dst"
  ok "Backup конфигурации → $dst"
}

safe_clean_impl(){
  sync_next_sources
  backup_current
  if [[ -x "$PROTECTION" ]]; then
    "$PROTECTION" uninstall || die 'Protection uninstall failed; safe clean aborted before deleting files.'
  fi
  "$GUARDS" remove-rkn-watch >/dev/null 2>&1 || true
  "$RKN" uninstall >/dev/null 2>&1 || true
  rm -rf /opt/remna-protection /var/log/remna-protection

  if [[ -f "$APP_DIR/docker-compose.yml" ]] && command -v docker >/dev/null 2>&1; then
    (cd "$APP_DIR" && docker compose down) || true
  fi
  if command -v docker >/dev/null 2>&1; then
    docker rm -f remnanode remnawave-nginx >/dev/null 2>&1 || true
  fi

  rm -rf "$APP_DIR"
  for link in "$CLI" /usr/local/bin/remnanode; do
    if [[ -L "$link" ]]; then
      target="$(readlink -f "$link" 2>/dev/null || true)"
      [[ "$target" == "$APP_DIR"/* ]] && rm -f "$link"
    fi
  done
  ok 'Удалён только Remnanode/NEXT stack. Docker как пакет, SSH, маршруты, DNS и чужие контейнеры не тронуты.'
}

safe_clean(){
  warn 'Будут удалены локальные Remnanode/Nginx/NEXT/RKN файлы этой ноды.'
  warn 'Перед удалением конфигурация будет сохранена в /root/remnanode-next-backup-*.tar.gz.'
  printf 'Для продолжения введи YES (0 = назад): '
  local answer; read -r answer < "$TTY" || true
  [[ "$answer" == YES ]] || { say 'Отменено.'; return 0; }
  safe_clean_impl
}

show_current_copy_profile(){
  local transport profile host1="" host2=""
  transport="$(cat "$APP_DIR/.transport" 2>/dev/null || true)"
  case "$transport" in
    xhttp)
      profile="$APP_DIR/remnawave-profiles/xhttp-reality.json"
      host1="$APP_DIR/remnawave-profiles/host-xhttp.txt"
      ;;
    raw)
      profile="$APP_DIR/remnawave-profiles/raw-reality.json"
      host1="$APP_DIR/remnawave-profiles/host-raw.txt"
      ;;
    hysteria)
      profile="$APP_DIR/remnawave-profiles/hysteria2-tls.json"
      host1="$APP_DIR/remnawave-profiles/host-hysteria2.txt"
      ;;
    combined)
      profile="$APP_DIR/remnawave-profiles/xhttp-hysteria2.json"
      host1="$APP_DIR/remnawave-profiles/host-xhttp.txt"
      host2="$APP_DIR/remnawave-profiles/host-hysteria2.txt"
      ;;
    *)
      warn 'Текущий transport не определён — профиль показать не могу.'
      return 1
      ;;
  esac

  [[ -s "$profile" ]] || { warn "Профиль не найден: $profile"; return 1; }

  echo
  echo '================ ГОТОВЫЙ CONFIG PROFILE — КОПИРУЙ ================='
  echo "Transport: $transport"
  echo "File:      $profile"
  echo
  cat "$profile"
  echo
  echo '================ КОНЕЦ CONFIG PROFILE =============================='
  if [[ -s "$host1" ]]; then
    echo
    echo '================ HOST SETTINGS ====================================='
    cat "$host1"
  fi
  if [[ -s "$host2" ]]; then
    echo
    echo '================ HOST SETTINGS 2 ==================================='
    cat "$host2"
  fi
  echo '====================================================================='
  warn 'В полном Config Profile может быть REALITY privateKey. Не публикуй этот вывод.'
}

offer_current_profile(){
  local answer
  echo
  printf 'ПОКАЗАТЬ ГОТОВЫЙ ПРОФИЛЬ / ПРОФИЛИ ДЛЯ КОПИПАСТЫ? [Y/n]: '
  read -r answer < "$TTY" || true
  case "${answer:-Y}" in
    Y|y|YES|yes|Да|да) show_current_copy_profile || true ;;
    *) say 'Профиль не выводил. В любой момент: sudo remnanode-next current-profile' ;;
  esac
}

network_menu(){
  sync_next_sources
  "$NETWORK" menu
}

rkn_default_active(){
  [[ -s "$APP_DIR/rkn-safe/.scanner-guard-active" ]] || return 1
  command -v iptables >/dev/null 2>&1 || return 1
  iptables -C INPUT -j REMNA_RKN_SCANNERS >/dev/null 2>&1
}

ensure_default_rkn(){
  if rkn_default_active; then
    ok 'RKN SAFE scanner guard уже установлен и активен.'
    return 0
  fi

  say '>>> DEFAULT: устанавливаю RKN SAFE scanner guard'
  RKN_ASSUME_KEEP=1 "$RKN" install-safe
}

ensure_default_network(){
  say '>>> DEFAULT: применяю BBR TUNE (SAFE/HIGHLOAD, без замены ядра)'
  "$NETWORK" ensure-default
}

run_install(){
  sync_next_sources
  if [[ ! -s "$APP_DIR/docker-compose.yml" ]] || ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
    legacy_call run_initial_setup
    sync_next_sources
  else
    ok 'Базовая Remnanode уже установлена — сохраняю её и перехожу к NEXT transport.'
  fi

  "$SELFSTEAL" ensure || warn 'SelfSteal site требует внимания.'
  "$TRANSPORT"
  post_transport

  echo
  echo '================ DEFAULT PROTECTION / NETWORK ================='
  local panel_ip=""
  [[ -r "$APP_DIR/.panel_ip" ]] && panel_ip="$(tr -d '[:space:]' < "$APP_DIR/.panel_ip")"
  if [[ -n "$panel_ip" ]]; then
    PANEL_IP_ENV="$panel_ip" "$PROTECTION" install || die 'Current semi-paranoid protection install failed.'
  else
    die 'PANEL_IP missing after base install; refusing to leave TCP/2222 without current protection.'
  fi
  "$GUARDS" sync-rkn-watch >/dev/null 2>&1 || warn 'Legacy RKN self-heal watcher требует внимания.'
  ensure_default_network || warn 'BBR TUNE не применён автоматически. Проверить: sudo remnanode-next network-status'
  echo '==============================================================='

  show_status
  offer_current_profile
}

run_reinstall(){
  warn 'Переустановка сначала сделает backup, затем удалит только текущий Remnanode/NEXT stack.'
  printf 'Для продолжения введи REINSTALL (0 = назад): '
  local answer; read -r answer < "$TTY" || true
  [[ "$answer" == REINSTALL ]] || { say 'Отменено.'; return 0; }
  sync_next_sources
  safe_clean_impl
  run_install
}

run_existing_node_v2(){
  warn 'NEXT V2 — установка на существующую/legacy ноду.'
  warn 'Запуск этого режима уже означает согласие на recovery backup, очистку старых Remnanode/Caddy/Hysteria/RKN хвостов и свежую установку NEXT.'
  warn 'SSH, hostname, DNS, default route, Docker как пакет и чужие контейнеры не затрагиваются.'

  sync_next_sources
  [[ -x "$V2_CLEANER" ]] || die "Не найден $V2_CLEANER"
  V2_ASSUME_YES=1 "$V2_CLEANER"
  run_install
}

telemt_menu(){
  sync_next_sources
  local c domain pass
  while true; do
    echo
    printf '%s%sTELEMT / MTPROTO%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%s────────────────────────────────────────────────────────────%s\n' "$C_GRAY" "$C_RESET"
    printf ' %s[1]%s Status / connection info\n' "$C_GREEN" "$C_RESET"
    printf ' %s[2]%s Install / repair (self-mask = node domain)\n' "$C_GREEN" "$C_RESET"
    printf ' %s[3]%s Disable services\n' "$C_YELLOW" "$C_RESET"
    printf ' %s[4]%s Uninstall binaries/units (config/data preserved)\n' "$C_RED" "$C_RESET"
    printf ' %s[0]%s Назад\n' "$C_GRAY" "$C_RESET"
    printf '%s────────────────────────────────────────────────────────────%s\n' "$C_GRAY" "$C_RESET"
    printf '%sВыбор:%s ' "$C_CYAN" "$C_RESET"; read -r c < "$TTY" || true
    case "$c" in
      1) "$TELEMT" status; pause ;;
      2)
        domain="$(cat "$APP_DIR/.node_domain" 2>/dev/null || hostname -f)"
        printf 'TLS/self-mask domain [%s]: ' "$domain"
        local entered; read -r entered < "$TTY" || true
        [[ -n "$entered" ]] && domain="$entered"
        printf 'Пароль Telemt Panel [Enter = сохранить текущий при repair]: '
        read -rs pass < "$TTY" || true
        echo
        if [[ -n "$pass" ]]; then
          TLS_DOMAIN="$domain" PANEL_PASSWORD="$pass" TELEMT_PORT=8443 "$TELEMT" install || { unset pass; warn 'Telemt install/repair не завершён.'; continue; }
        else
          TLS_DOMAIN="$domain" TELEMT_PORT=8443 "$TELEMT" install || { warn 'Для новой установки нужен пароль; существующая установка не изменена.'; continue; }
        fi
        unset pass
        pause
        ;;
      3) "$TELEMT" disable; pause ;;
      4) "$TELEMT" uninstall; pause ;;
      0|'') return 0 ;;
      *) warn 'Неверный пункт.' ;;
    esac
  done
}
protection_menu(){
  sync_next_sources
  "$PROTECTION" menu
}

rebuild_menu(){
  sync_next_sources
  local c
  while true; do
    cat <<'MENU'

LEGACY NODE REBUILD
────────────────────────────────────────────────────────────
 [1] Discover current node identity
 [2] Status / postcheck
 [3] Показать команду managed rebuild
 [0] Назад
────────────────────────────────────────────────────────────
MENU
    printf 'Выбор: '; read -r c < "$TTY" || true
    case "$c" in
      1) "$REBUILD" discover; pause ;;
      2) "$REBUILD" status; pause ;;
      3)
        say 'Пример:'
        say 'NODE_DOMAIN=node.example.com PANEL_IP=203.0.113.10 LEGACY_UFW_PORTS="2443 4443" sudo /opt/remnanode/next-installer/legacy-rebuild-manager.sh rebuild'
        pause
        ;;
      0|'') return 0 ;;
      *) warn 'Неверный пункт.' ;;
    esac
  done
}

main_menu(){
  sync_next_sources
  local c
  while true; do
    echo
    printf '%s%sREMNANODE NEXT — управление нодой%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%sREPO:%s https://github.com/evgmahov-blip/remna-node-scripts\n' "$C_GRAY" "$C_RESET"
    printf '%sCLI:%s  sudo remnanode-next\n' "$C_GRAY" "$C_RESET"
    printf '%s────────────────────────────────────────────────────────────%s\n' "$C_GRAY" "$C_RESET"
    printf '%sБЫСТРЫЕ ДЕЙСТВИЯ%s\n' "$C_BOLD$C_GREEN" "$C_RESET"
    printf ' %s[1]%s  Установить / продолжить настройку\n' "$C_GREEN" "$C_RESET"
    printf ' %s[9]%s  Статус ноды\n' "$C_GREEN" "$C_RESET"
    printf ' %s[15]%s Анализ / тестирование ноды\n' "$C_GREEN" "$C_RESET"
    echo
    printf '%sТРАНСПОРТ / REMNAWAVE%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
    printf ' %s[2]%s  Транспорт и профили\n' "$C_CYAN" "$C_RESET"
    printf ' %s[3]%s  Config Profile + Host\n' "$C_CYAN" "$C_RESET"
    printf ' %s[4]%s  SelfSteal\n' "$C_CYAN" "$C_RESET"
    printf ' %s[5]%s  XHTTP signature\n' "$C_CYAN" "$C_RESET"
    echo
    printf '%sЗАЩИТА / СЕТЬ%s\n' "$C_BOLD$C_YELLOW" "$C_RESET"
    printf ' %s[6]%s  Semi-paranoid protection\n' "$C_YELLOW" "$C_RESET"
    printf ' %s[13]%s Network / BBR\n' "$C_YELLOW" "$C_RESET"
    printf ' %s[14]%s Hysteria2 diagnostics\n' "$C_YELLOW" "$C_RESET"
    echo
    printf '%sTELEGRAM / TELEMT%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
    printf ' %s[16]%s MTProto proxy + Telemt Panel\n' "$C_CYAN" "$C_RESET"
    echo
    printf '%sОБСЛУЖИВАНИЕ%s\n' "$C_BOLD$C_GRAY" "$C_RESET"
    printf ' %s[7]%s  Runtime repair\n' "$C_GRAY" "$C_RESET"
    printf ' %s[8]%s  Remnanode management\n' "$C_GRAY" "$C_RESET"
    printf ' %s[10]%s Safe clean\n' "$C_YELLOW" "$C_RESET"
    printf ' %s[11]%s Safe reinstall\n' "$C_YELLOW" "$C_RESET"
    printf ' %s[12]%s Legacy → NEXT V2\n' "$C_YELLOW" "$C_RESET"
    printf ' %s[17]%s Managed rebuild\n' "$C_YELLOW" "$C_RESET"
    printf ' %s[0]%s  Выход\n' "$C_GRAY" "$C_RESET"
    printf '%s────────────────────────────────────────────────────────────%s\n' "$C_GRAY" "$C_RESET"
    printf '%sВыбор:%s ' "$C_CYAN" "$C_RESET"; read -r c < "$TTY" || true
    case "$c" in
      1) run_install; pause ;;
      2) transport_menu; pause ;;
      3) copy_profile_menu ;;
      4) "$SELFSTEAL" choose; pause ;;
      5) signature_menu ;;
      6) protection_menu ;;
      7) runtime_menu ;;
      8) base_manage_menu ;;
      9) show_status; pause ;;
      10) safe_clean; pause ;;
      11) run_reinstall; pause ;;
      12) run_existing_node_v2; pause ;;
      13) network_menu ;;
      14) hysteria_diag; pause ;;
      15) "$TESTER" menu ;;
      16) telemt_menu ;;
      17) rebuild_menu ;;
      0|'') return 0 ;;
      *) warn 'Неверный пункт.' ;;
    esac
  done
}

main(){
  need_root
  case "${1:-menu}" in
    menu|'') main_menu ;;
    install|install-next) run_install ;;
    reinstall|full-reinstall) run_reinstall ;;
    migrate-existing|install-v2|legacy-to-next) run_existing_node_v2 ;;
    clean) safe_clean ;;
    transport) sync_next_sources; shift; "$TRANSPORT" "$@"; post_transport ;;
    profile|profiles|hosts) copy_profile_menu ;;
    host-xhttp) sync_next_sources; cat "$APP_DIR/remnawave-profiles/host-xhttp.txt" ;;
    host-hysteria2|host-hysteria) sync_next_sources; cat "$APP_DIR/remnawave-profiles/host-hysteria2.txt" ;;
    host-raw) sync_next_sources; cat "$APP_DIR/remnawave-profiles/host-raw.txt" ;;
    selfsteal) sync_next_sources; shift; "$SELFSTEAL" "${1:-choose}" "${2:-}" ;;
    rkn|protection|security) sync_next_sources; shift; "$PROTECTION" "${1:-menu}" ;;
    telemt|mtproto) sync_next_sources; shift; "$TELEMT" "${1:-status}" ;;
    rebuild-manager|legacy-rebuild) sync_next_sources; shift; "$REBUILD" "${1:-discover}" ;;
    managed-update) run_managed_update ;;
    release-status) release_status ;;
    signature) sync_next_sources; shift; "$SIGNATURE" "${1:-apply}" ;;
    runtime) sync_next_sources; shift; "$GUARDS" "$@" ;;
    status) show_status ;;
    current-profile|copy-profile-now) show_current_copy_profile ;;
    network) sync_next_sources; "$NETWORK" menu ;;
    network-status) sync_next_sources; "$NETWORK" status ;;
    bbr-tune) sync_next_sources; "$NETWORK" tune ;;
    bbr3) sync_next_sources; "$NETWORK" bbr3 ;;
    hysteria-diag|hy2-diag) hysteria_diag ;;
    multitest|server-test|tests) sync_next_sources; shift; "$TESTER" "${1:-menu}" ;;
    sync-source) sync_next_sources ;;
    *) die 'Использование: full-clean-reinstall.sh [menu|install|reinstall|migrate-existing|install-v2|legacy-to-next|clean|transport|profiles|hosts|host-xhttp|host-hysteria2|host-raw|current-profile|selfsteal|rkn|protection|security|telemt|mtproto|rebuild-manager|legacy-rebuild|managed-update|release-status|signature|runtime|status|network|network-status|bbr-tune|bbr3|hysteria-diag|multitest|sync-source]' ;;
  esac
}

main "$@"
