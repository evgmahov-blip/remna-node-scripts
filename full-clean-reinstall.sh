#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

TASK_NAME="REMNA NODE NEXT"
REPO="evgmahov-blip/remna-node-scripts"
SOURCE_REF="721269e2c48e31b7cac86e04bc14c46b33e31e72"
SOURCE_BLOB_SHA="51a91d5745d0bea9b03eefeeaac52677fcf56b60"
SOURCE_URL="https://raw.githubusercontent.com/${REPO}/${SOURCE_REF}/vendor/remna-next-source.tar.gz"
HYSTERIA_OVERLAY_REF="6f02c87c10d1d47fb4abcb234755823d1a1067bf"
HYSTERIA_OVERLAY_BLOB_SHA="62ff1364c26d88f357968422d5591b3d2b8d9e78"
HYSTERIA_OVERLAY_URL="https://raw.githubusercontent.com/${REPO}/${HYSTERIA_OVERLAY_REF}/next-installer/remnawave-transport-manager.sh"
V2_CLEANUP_REF="551a80ca1802d3087c53edf12652f104cd1c721d"
V2_CLEANUP_BLOB_SHA="755e94a26fa7cc835e65ce415c9d87f07a7fa86e"
V2_CLEANUP_URL="https://raw.githubusercontent.com/${REPO}/${V2_CLEANUP_REF}/next-installer/existing-node-v2-cleanup.sh"
NETWORK_REF="dd7474f8f72b7d4b56221e89bb969ac75b2dff00"
NETWORK_BLOB_SHA="8616189227534a4c651000d233162b1603a50d7b"
NETWORK_URL="https://raw.githubusercontent.com/${REPO}/${NETWORK_REF}/next-installer/network-tuning-manager.sh"
TESTER_REF="c01a37bd29f4da3da270972f44ae799f177aeadd"
TESTER_BLOB_SHA="bddab73a3b427b80fef222dc65b15852c93e7b55"
TESTER_URL="https://raw.githubusercontent.com/${REPO}/${TESTER_REF}/next-installer/server-multitest.sh"

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
TTY=/dev/tty
[[ -r "$TTY" ]] || TTY=/dev/stdin

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
  grep -Fq 'https://github.com/Balbuto/safe-remnanode-setup' "$network" || die 'Network/BBR manager: BBR tune source link отсутствует.'

  local tester
  tester="$tmp/next-installer/server-multitest.sh"
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 --retry 3 \
    "$TESTER_URL" -o "$tester" || die 'Не удалось скачать Server Multitest.'
  [[ "$(git_blob_sha "$tester")" == "$TESTER_BLOB_SHA" ]] || die 'Server Multitest не прошёл Git blob SHA.'
  bash -n "$tester" || die 'Server Multitest не прошёл bash -n.'
  grep -Fq 'Balbuto/safe-remnanode-setup' "$tester" || die 'Server Multitest: provenance marker отсутствует.'
  grep -Fq 'Censorcheck — DPI' "$tester" || die 'Server Multitest: Censorcheck DPI отсутствует.'
  grep -Fq 'iPerf3 — bench.tlab.pw' "$tester" || die 'Server Multitest: iPerf3 tlab отсутствует.'
  grep -Fq 'Network Bench (HTTPS 100MB)' "$tester" || die 'Server Multitest: HTTPS network bench отсутствует.'
  if grep -Eq '(^|[^[:alnum:]])http://' "$tester"; then
    die 'Server Multitest содержит небезопасный HTTP URL.'
  fi

  install -d -m 0700 "$NEXT_DIR" /usr/local/libexec
  install -m 0700 "$tmp/next-installer/"*.sh "$NEXT_DIR/"

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
    opt/remnanode/remnawave-profiles
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
  "$GUARDS" remove-rkn-watch >/dev/null 2>&1 || true
  "$RKN" uninstall >/dev/null 2>&1 || true

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
  ensure_default_rkn || warn 'RKN SAFE scanner guard не удалось установить автоматически. Доступно вручную: sudo remnanode-next rkn'
  "$GUARDS" sync-rkn-watch >/dev/null 2>&1 || warn 'RKN self-heal watcher требует внимания.'
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

main_menu(){
  sync_next_sources
  local c
  while true; do
    cat <<'MENU'

REMNANODE NEXT — MAIN
REPO: https://github.com/evgmahov-blip/remna-node-scripts
CLI:  sudo remnanode-next
────────────────────────────────────────────────────────────
 [1]  Установка / продолжить настройку NEXT
 [2]  Транспорт / профили (XHTTP / RAW / Hysteria2 / combined)
 [3]  Config Profile + НАСТРОЙКИ HOST REMNAWAVE
 [4]  SelfSteal / маскировочный сайт
 [5]  XHTTP signature
 [6]  РКН защита — SAFE scanner guard (DEFAULT)
 [7]  Runtime repair / guards
 [8]  Базовое управление Remnanode
 [9]  Статус
 [10] Safe clean текущей NEXT-ноды
 [11] Safe reinstall текущей NEXT-ноды
 [12] NEXT V2 — существующая/legacy нода → очистка хвостов → NEXT

 [13] СЕТЬ / BBR TUNE (DEFAULT) / BBR3 (OPTIONAL)
 [14] HYSTERIA2 DIAG — UDP/443 + DNS + RKN counters
 [15] МУЛЬТИ-ТЕСТЫ СЕРВЕРА — Balbuto Module D
      RUN:    sudo remnanode-next multitest
      TEST:   sudo remnanode-next multitest 1..14
      RUN:    sudo remnanode-next network
      TUNE:   https://github.com/Balbuto/safe-remnanode-setup
      BBR3:   https://github.com/ivan-nginx/bbr3

 [0]  Выход
────────────────────────────────────────────────────────────
MENU
    printf 'Выбор: '; read -r c < "$TTY" || true
    case "$c" in
      1) run_install; pause ;;
      2) transport_menu; pause ;;
      3) copy_profile_menu ;;
      4) "$SELFSTEAL" choose; pause ;;
      5) signature_menu ;;
      6) "$RKN" menu ;;
      7) runtime_menu ;;
      8) base_manage_menu ;;
      9) show_status; pause ;;
      10) safe_clean; pause ;;
      11) run_reinstall; pause ;;
      12) run_existing_node_v2; pause ;;
      13) network_menu ;;
      14) hysteria_diag; pause ;;
      15) "$TESTER" menu ;;
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
    rkn) sync_next_sources; shift; "$RKN" "${1:-menu}" ;;
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
    *) die 'Использование: full-clean-reinstall.sh [menu|install|reinstall|migrate-existing|install-v2|legacy-to-next|clean|transport|profiles|hosts|host-xhttp|host-hysteria2|host-raw|current-profile|selfsteal|rkn|signature|runtime|status|network|network-status|bbr-tune|bbr3|hysteria-diag|multitest|sync-source]' ;;
  esac
}

main "$@"
