#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# REMNANODE NEXT — server multitest
# Derived from Module D of:
#   https://github.com/Balbuto/safe-remnanode-setup
# Source commit: 274d84d9daa3b4d4a33264ba77992210aedd9b32
# Source script blob: 58a85a9baa4f36648d6587c5d6c4ac347096963d
# Upstream module states that it was actualized from saveksme/multitest v1.1.
#
# Adaptations for REMNANODE NEXT:
# - standalone tester only; no node/firewall/sysctl installer code;
# - no HTTP downloads: external scripts and network bench use HTTPS only;
# - external scripts are downloaded to a temporary file and pass bash -n;
# - dependencies are installed only when the selected test needs them.

SOURCE_REPO="Balbuto/safe-remnanode-setup"
SOURCE_REF="274d84d9daa3b4d4a33264ba77992210aedd9b32"
SOURCE_BLOB_SHA="58a85a9baa4f36648d6587c5d6c4ac347096963d"

TTY=/dev/tty
[[ -r "$TTY" ]] || TTY=/dev/stdin

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_CYAN=$'\033[36m'
  C_YELLOW=$'\033[33m'
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_GRAY=$'\033[90m'
else
  C_RESET=""
  C_CYAN=""
  C_YELLOW=""
  C_GREEN=""
  C_RED=""
  C_GRAY=""
fi

say(){ printf '%s\n' "$*"; }
warn(){ printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail(){ printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; return 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { fail 'Запусти от root.'; exit 1; }; }
pause(){ printf 'Enter — продолжить... '; read -r _ < "$TTY" || true; }

APT_UPDATED=0
apt_install(){
  local pkgs=("$@")
  command -v apt-get >/dev/null 2>&1 || { fail "apt-get недоступен; установи вручную: ${pkgs[*]}"; return 1; }
  if (( ! APT_UPDATED )); then
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update -y
    APT_UPDATED=1
  fi
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y "${pkgs[@]}"
}

need_cmd(){
  local cmd="$1"
  shift
  local pkgs=("$@")
  (( ${#pkgs[@]} > 0 )) || pkgs=("$cmd")
  if ! command -v "$cmd" >/dev/null 2>&1; then
    say ">>> Устанавливаю зависимость для теста: ${pkgs[*]}"
    apt_install "${pkgs[@]}"
  fi
}

download_external_script(){
  local name="$1" url="$2" dst="$3"
  [[ "$url" == https://* ]] || { fail "Заблокирован не-HTTPS URL: $url"; return 1; }
  need_cmd curl curl ca-certificates || return 1
  printf '%sИсточник:%s %s\n' "$C_GRAY" "$C_RESET" "$url"
  if ! curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 --retry 2 -o "$dst" "$url"; then
    fail "Не удалось скачать $name"
    return 1
  fi
  printf 'SHA256: %s\n' "$(sha256sum "$dst" | awk '{print $1}')"
  printf 'Size:   %s bytes\n' "$(wc -c < "$dst" | tr -d '[:space:]')"
  if ! bash -n "$dst"; then
    fail "$name скачан, но не прошёл bash -n; запуск заблокирован."
    return 1
  fi
  chmod 0700 "$dst"
}

run_external_script(){
  local name="$1" url="$2"
  shift 2
  local tmp rc=0
  tmp="$(mktemp "/tmp/remna-multitest.XXXXXX.sh")"
  trap 'rm -f "$tmp"' RETURN
  echo
  printf '%s================ %s ================%s\n' "$C_CYAN" "$name" "$C_RESET"
  warn 'Внешний тестовый скрипт загружается динамически по HTTPS; upstream SHA не закреплён.'
  if download_external_script "$name" "$url" "$tmp"; then
    set +e
    bash "$tmp" "$@"
    rc=$?
    set -e
  else
    rc=1
  fi
  rm -f "$tmp"
  trap - RETURN
  return "$rc"
}

test_ip_region(){
  need_cmd curl curl ca-certificates
  need_cmd jq jq
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 30 https://ipapi.co/json 2>/dev/null |
    jq '.' 2>/dev/null ||
    curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 30 https://ipinfo.io 2>/dev/null ||
    say 'Ошибка получения данных.'
}

test_censor_geoblock(){
  run_external_script "Censorcheck — геоблок"     "https://github.com/vernette/censorcheck/raw/master/censorcheck.sh"     --mode geoblock || true
}

test_censor_dpi(){
  run_external_script "Censorcheck — DPI"     "https://github.com/vernette/censorcheck/raw/master/censorcheck.sh"     --mode dpi || true
}

test_iperf_ru(){
  need_cmd iperf3 iperf3 || true
  run_external_script "iPerf3 — RU сервера"     "https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh" || true
}

test_iperf_tlab(){
  need_cmd iperf3 iperf3 || true
  run_external_script "iPerf3 — bench.tlab.pw" "https://bench.tlab.pw" || true
}

test_yabs(){
  run_external_script "YABS" "https://yabs.sh" -4 || true
}

test_ip_check_place(){
  run_external_script "IP Check Place" "https://ip.check.place/script/check.sh" -l ru || true
}

test_ipquality(){
  run_external_script "IPQuality" "https://check.place/script/check.sh" -l ru -I || true
}

test_sysbench_cpu(){
  need_cmd sysbench sysbench
  sysbench cpu --cpu-max-prime=20000 run || true
}

test_sysbench_memory(){
  need_cmd sysbench sysbench
  sysbench memory run || true
}

test_network_100mb(){
  need_cmd curl curl ca-certificates
  say 'Network Bench: HTTPS download 100 MB via Cloudflare speed endpoint'
  curl -4 -fL --proto '=https' --tlsv1.2     --connect-timeout 10 --max-time 180     -o /dev/null     -w $'Downloaded: %{size_download} bytes\nAverage:    %{speed_download} bytes/s\nTime:       %{time_total} s\n'     'https://speed.cloudflare.com/__down?bytes=100000000' || true
}

test_tls(){
  need_cmd openssl openssl
  if openssl s_client -connect google.com:443 -servername google.com -tls1_2 </dev/null 2>&1 | grep -q 'Protocol'; then
    say 'TLS 1.2 OK'
  else
    say 'TLS 1.2 недоступен'
  fi
  if openssl s_client -connect google.com:443 -servername google.com -tls1_3 </dev/null 2>&1 | grep -q 'Protocol'; then
    say 'TLS 1.3 OK'
  else
    say 'TLS 1.3 недоступен'
  fi
}

test_traceroute(){
  need_cmd traceroute traceroute
  traceroute -n yandex.ru || true
}

test_ping(){
  need_cmd ping iputils-ping
  ping -c 4 yandex.ru || true
}

run_one(){
  case "${1:-}" in
    1) test_ip_region ;;
    2) test_censor_geoblock ;;
    3) test_censor_dpi ;;
    4) test_iperf_ru ;;
    5) test_iperf_tlab ;;
    6) test_yabs ;;
    7) test_ip_check_place ;;
    8) test_ipquality ;;
    9) test_sysbench_cpu ;;
    10) test_sysbench_memory ;;
    11) test_network_100mb ;;
    12) test_tls ;;
    13) test_traceroute ;;
    14) test_ping ;;
    *) fail "Неизвестный тест: ${1:-пусто}"; return 2 ;;
  esac
}

run_interruptible(){
  local num="$1" rc
  trap '' INT
  set +e
  ( trap - INT; run_one "$num" )
  rc=$?
  set -e
  trap - INT
  if (( rc == 130 )); then
    say 'Текущий тест прерван Ctrl+C; продолжаю.'
    return 0
  fi
  return "$rc"
}

print_list(){
  cat <<'EOF'
 1) IP Region / Геолокация
 2) Censorcheck — геоблок
 3) Censorcheck — DPI
 4) iPerf3 — RU сервера
 5) iPerf3 — bench.tlab.pw (РФ)
 6) YABS
 7) IP Check Place
 8) IPQuality
 9) sysbench CPU
10) sysbench Memory
11) Network Bench (HTTPS 100MB)
12) SSL/TLS check
13) Traceroute yandex.ru
14) Ping yandex.ru
99) Мультитест: все тесты по очереди
EOF
}

run_all(){
  local names=(
    "IP Region"
    "Censorcheck — проверка геоблока"
    "Censorcheck — DPI"
    "iPerf3 — российские серверы"
    "iPerf3 — bench.tlab.pw"
    "YABS — benchmark"
    "IP Check Place"
    "IPQuality"
    "sysbench CPU"
    "sysbench Memory"
    "Network Bench — HTTPS 100MB"
    "SSL/TLS check"
    "Traceroute yandex.ru"
    "Ping yandex.ru"
  )
  local total="${#names[@]}" i num action rc
  printf '%sEnter%s — запустить | %ss%s — пропустить | %sq%s — выход\n'     "$C_YELLOW" "$C_RESET" "$C_YELLOW" "$C_RESET" "$C_YELLOW" "$C_RESET"
  printf '%sCtrl+C во время теста — пропустить текущий и продолжить%s\n' "$C_GRAY" "$C_RESET"
  for ((i=0; i<total; i++)); do
    num=$((i+1))
    echo
    printf '%s============ [%s/%s] %s ============ %s\n'       "$C_CYAN" "$num" "$total" "${names[$i]}" "$C_RESET"
    printf 'Enter — запустить | s — пропустить | q — выход: '
    read -r action < "$TTY" || action=q
    case "$action" in
      s|S) say 'Пропущено.'; continue ;;
      q|Q) say "Мультитест остановлен: дошли до $((num-1))/$total."; return 0 ;;
    esac
    rc=0
    run_interruptible "$num" || rc=$?
    (( rc == 0 )) || warn "Тест $num завершился с rc=$rc"
  done
  printf '%sВсе тесты завершены: %s/%s%s\n' "$C_GREEN" "$total" "$total" "$C_RESET"
}

menu(){
  local choice
  while true; do
    echo
    printf '%s============================================================%s\n' "$C_CYAN" "$C_RESET"
    say 'REMNANODE NEXT — SERVER MULTITEST'
    say "Source: $SOURCE_REPO @ $SOURCE_REF"
    printf '%s============================================================%s\n' "$C_CYAN" "$C_RESET"
    print_list
    say ' 0) Назад'
    echo
    printf 'Выбор: '
    read -r choice < "$TTY" || choice=0
    case "$choice" in
      1|2|3|4|5|6|7|8|9|10|11|12|13|14) run_interruptible "$choice" || true; pause ;;
      99) run_all; pause ;;
      0|'') return 0 ;;
      *) warn 'Неверный выбор.' ;;
    esac
  done
}

usage(){
  cat <<'EOF'
Usage:
  server-multitest.sh menu
  server-multitest.sh list
  server-multitest.sh all
  server-multitest.sh 1..14
EOF
}

main(){
  need_root
  case "${1:-menu}" in
    menu|'') menu ;;
    list) print_list ;;
    all|99) run_all ;;
    1|2|3|4|5|6|7|8|9|10|11|12|13|14) run_interruptible "$1" ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
