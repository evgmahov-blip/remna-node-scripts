#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# REMNANODE NEXT — server multitest
# Derived from Module D of:
#   https://github.com/Balbuto/safe-remnanode-setup
# Source commit: 274d84d9daa3b4d4a33264ba77992210aedd9b32
# Source script blob: 58a85a9baa4f36648d6587c5d6c4ac347096963d
#
# REMNANODE NEXT audit adaptations:
# - standalone tester only; no node/firewall/sysctl installer code;
# - all wrapper downloads are HTTPS only;
# - GitHub-hosted entry scripts are pinned to immutable commits + Git blob SHA;
# - external scripts pass bash -n before execution;
# - dependencies are installed only when the selected test needs them;
# - failed tests propagate a non-zero result instead of being silently hidden;
# - duplicate IP-quality test replaced with a geo/media unlock test;
# - YABS is run without the incorrect "-4" flag ("-4" means Geekbench 4, not IPv4).

SOURCE_REPO="Balbuto/safe-remnanode-setup"
SOURCE_REF="274d84d9daa3b4d4a33264ba77992210aedd9b32"
SOURCE_BLOB_SHA="58a85a9baa4f36648d6587c5d6c4ac347096963d"

CENSOR_REF="42a688b855b37bc6e97eace1897df38897b8d9fe"
CENSOR_BLOB_SHA="4b12652cd83112f5c615fdf6af1048aa7abca958"
CENSOR_URL="https://raw.githubusercontent.com/vernette/censorcheck/${CENSOR_REF}/censorcheck.sh"

IPERF_RU_REF="3e3e29c89798b652ac04429dd8b7a02f79050970"
IPERF_RU_BLOB_SHA="d0b1986cdb4c34203758d63706c929728669c9e6"
IPERF_RU_URL="https://raw.githubusercontent.com/itdoginfo/russian-iperf3-servers/${IPERF_RU_REF}/speedtest.sh"

YABS_REF="316260707a0db8ccd83d7f5ac9d643f21396b44c"
YABS_BLOB_SHA="e2d9c97e966a31d10e0676698c9a7c60c1315ccb"
YABS_URL="https://raw.githubusercontent.com/masonr/yet-another-bench-script/${YABS_REF}/yabs.sh"

REGION_REF="b6d4a6f9a87fc6eae6d3e62d0092ececcec8e844"
REGION_BLOB_SHA="36b594883cd88e608a2191999244eed595878e34"
REGION_URL="https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/${REGION_REF}/check.sh"

IPQUALITY_REF="2384a67c756eb35231f5982b34731e522be3653e"
IPQUALITY_BLOB_SHA="086792f3be803fa0b1c0af6eb9247207abb7e182"
IPQUALITY_URL="https://raw.githubusercontent.com/xykt/IPQuality/${IPQUALITY_REF}/ip.sh"

TLAB_URL="https://bench.tlab.pw"
NETWORK_BENCH_URL="https://speed.cloudflare.com/__down?bytes=100000000"

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

git_blob_sha(){
  local file="$1" size
  size="$(wc -c <"$file" | tr -d '[:space:]')"
  { printf 'blob %s\000' "$size"; cat "$file"; } | sha1sum | awk '{print $1}'
}

APT_UPDATED=0
apt_install(){
  local pkgs=("$@")
  command -v apt-get >/dev/null 2>&1 || {
    fail "apt-get недоступен; установи вручную: ${pkgs[*]}"
    return 1
  }
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
    apt_install "${pkgs[@]}" || return 1
  fi
  command -v "$cmd" >/dev/null 2>&1 || {
    fail "Команда $cmd недоступна после установки."
    return 1
  }
}

download_external_script(){
  local name="$1" url="$2" dst="$3" expected_blob="${4:-}"
  local got_blob
  [[ "$url" == https://* ]] || {
    fail "Заблокирован не-HTTPS URL: $url"
    return 1
  }
  need_cmd curl curl ca-certificates || return 1
  printf '%sИсточник:%s %s\n' "$C_GRAY" "$C_RESET" "$url"
  if ! curl -fsSL --proto '=https' --tlsv1.2       --connect-timeout 10 --max-time 120 --retry 2       -o "$dst" "$url"; then
    fail "Не удалось скачать $name"
    return 1
  fi
  got_blob="$(git_blob_sha "$dst")"
  printf 'SHA256:   %s\n' "$(sha256sum "$dst" | awk '{print $1}')"
  printf 'Git blob: %s\n' "$got_blob"
  printf 'Size:     %s bytes\n' "$(wc -c < "$dst" | tr -d '[:space:]')"
  if [[ -n "$expected_blob" && "$got_blob" != "$expected_blob" ]]; then
    fail "$name: Git blob SHA mismatch: $got_blob != $expected_blob"
    return 1
  fi
  if ! bash -n "$dst"; then
    fail "$name скачан, но не прошёл bash -n; запуск заблокирован."
    return 1
  fi
  chmod 0700 "$dst"
}

run_external_script(){
  local name="$1" url="$2" expected_blob="${3:-}"
  shift 3
  local tmp rc=0
  tmp="$(mktemp "/tmp/remna-multitest.XXXXXX.sh")"
  echo
  printf '%s================ %s ================%s\n' "$C_CYAN" "$name" "$C_RESET"
  if [[ -n "$expected_blob" ]]; then
    say "Entry script pinned: $expected_blob"
  else
    warn 'Этот внешний entry script не имеет закреплённого upstream SHA.'
  fi
  if download_external_script "$name" "$url" "$tmp" "$expected_blob"; then
    set +e
    bash "$tmp" "$@"
    rc=$?
    set -e
  else
    rc=1
  fi
  rm -f "$tmp"
  return "$rc"
}

prepare_censorcheck(){
  need_cmd curl curl ca-certificates
  need_cmd dig dnsutils
  need_cmd jq jq
  need_cmd column bsdextrautils
}

prepare_iperf_ru(){
  need_cmd iperf3 iperf3
  need_cmd jq jq
  need_cmd ping iputils-ping
  need_cmd awk gawk
  need_cmd timeout coreutils
}

prepare_regioncheck(){
  need_cmd curl curl ca-certificates
  need_cmd openssl openssl
  need_cmd uuidgen uuid-runtime
  need_cmd dig dnsutils
}

test_ip_region(){
  need_cmd curl curl ca-certificates
  need_cmd jq jq
  local data=""
  data="$(curl -fsSL --proto '=https' --tlsv1.2     --connect-timeout 10 --max-time 30 https://ipapi.co/json 2>/dev/null || true)"
  if [[ -n "$data" ]] && jq -e . >/dev/null 2>&1 <<<"$data"; then
    jq '.' <<<"$data"
    return 0
  fi
  data="$(curl -fsSL --proto '=https' --tlsv1.2     --connect-timeout 10 --max-time 30 https://ipinfo.io/json 2>/dev/null || true)"
  if [[ -n "$data" ]] && jq -e . >/dev/null 2>&1 <<<"$data"; then
    jq '.' <<<"$data"
    return 0
  fi
  fail 'Не удалось получить валидные IP/Geo данные ни от ipapi.co, ни от ipinfo.io.'
}

test_censor_geoblock(){
  prepare_censorcheck
  run_external_script     "Censorcheck — геоблок"     "$CENSOR_URL"     "$CENSOR_BLOB_SHA"     --mode geoblock
}

test_censor_dpi(){
  prepare_censorcheck
  run_external_script     "Censorcheck — DPI"     "$CENSOR_URL"     "$CENSOR_BLOB_SHA"     --mode dpi
}

test_iperf_ru(){
  prepare_iperf_ru
  run_external_script     "iPerf3 — RU сервера"     "$IPERF_RU_URL"     "$IPERF_RU_BLOB_SHA"
}

test_iperf_tlab(){
  need_cmd iperf3 iperf3
  run_external_script     "iPerf3 — bench.tlab.pw"     "$TLAB_URL"     ""
}

test_yabs(){
  # В YABS -4 = Geekbench 4, а не IPv4. Запускаем обычный актуальный профиль.
  run_external_script     "YABS"     "$YABS_URL"     "$YABS_BLOB_SHA"
}

test_geo_unlock(){
  prepare_regioncheck
  warn 'RegionRestrictionCheck entry script pinned; его собственные cookies/reference data upstream остаются сетевыми.'
  run_external_script     "Geo/Media Unlock — RegionRestrictionCheck"     "$REGION_URL"     "$REGION_BLOB_SHA"     -M 4 -R 0 -E en
}

test_ipquality(){
  need_cmd curl curl ca-certificates
  need_cmd jq jq
  warn 'IPQuality обращается к множеству внешних IP/risk/media API; расхождения между базами нормальны.'
  run_external_script     "IPQuality"     "$IPQUALITY_URL"     "$IPQUALITY_BLOB_SHA"     -l ru -y
}

test_sysbench_cpu(){
  need_cmd sysbench sysbench
  sysbench cpu --cpu-max-prime=20000 run
}

test_sysbench_memory(){
  need_cmd sysbench sysbench
  sysbench memory run
}

test_network_100mb(){
  need_cmd curl curl ca-certificates
  local result bytes speed seconds
  say 'Network Bench: HTTPS download 100 MB via Cloudflare speed endpoint'
  result="$(curl -4 -fsSL --proto '=https' --tlsv1.2     --connect-timeout 10 --max-time 180     -o /dev/null     -w '%{size_download} %{speed_download} %{time_total}'     "$NETWORK_BENCH_URL")" || return 1
  read -r bytes speed seconds <<<"$result"
  awk -v b="$bytes" -v s="$speed" -v t="$seconds" '
    BEGIN {
      printf "Downloaded: %.2f MB\n", b / 1000000
      printf "Average:    %.2f Mbit/s\n", s * 8 / 1000000
      printf "Time:       %.2f s\n", t
    }
  '
}

test_tls(){
  need_cmd openssl openssl
  local failed=0 out
  out="$(openssl s_client -brief -connect google.com:443 -servername google.com -tls1_2 </dev/null 2>&1)" || failed=1
  if grep -Eq 'Protocol version: TLSv1\.2|Protocol[[:space:]]*:[[:space:]]*TLSv1\.2' <<<"$out"; then
    say 'TLS 1.2 OK'
  else
    say 'TLS 1.2 недоступен'
    failed=1
  fi

  out="$(openssl s_client -brief -connect google.com:443 -servername google.com -tls1_3 </dev/null 2>&1)" || failed=1
  if grep -Eq 'Protocol version: TLSv1\.3|Protocol[[:space:]]*:[[:space:]]*TLSv1\.3' <<<"$out"; then
    say 'TLS 1.3 OK'
  else
    say 'TLS 1.3 недоступен'
    failed=1
  fi
  return "$failed"
}

test_traceroute(){
  need_cmd traceroute traceroute
  traceroute -n yandex.ru
}

test_ping(){
  need_cmd ping iputils-ping
  ping -c 4 yandex.ru
}

run_one(){
  case "${1:-}" in
    1) test_ip_region ;;
    2) test_censor_geoblock ;;
    3) test_censor_dpi ;;
    4) test_iperf_ru ;;
    5) test_iperf_tlab ;;
    6) test_yabs ;;
    7) test_geo_unlock ;;
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
    say 'Текущий тест прерван Ctrl+C.'
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
 7) Geo/Media Unlock — RegionRestrictionCheck
 8) IPQuality — ASN / risk / blacklist / media / mail
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
    "Geo/Media Unlock — RegionRestrictionCheck"
    "IPQuality"
    "sysbench CPU"
    "sysbench Memory"
    "Network Bench — HTTPS 100MB"
    "SSL/TLS check"
    "Traceroute yandex.ru"
    "Ping yandex.ru"
  )
  local total="${#names[@]}" i num action rc
  local passed=0 failed=0 skipped=0

  printf '%sEnter%s — запустить | %ss%s — пропустить | %sq%s — выход\n'     "$C_YELLOW" "$C_RESET" "$C_YELLOW" "$C_RESET" "$C_YELLOW" "$C_RESET"
  printf '%sCtrl+C во время теста — пропустить только текущий%s\n' "$C_GRAY" "$C_RESET"

  for ((i=0; i<total; i++)); do
    num=$((i+1))
    echo
    printf '%s============ [%s/%s] %s ============ %s\n'       "$C_CYAN" "$num" "$total" "${names[$i]}" "$C_RESET"
    printf 'Enter — запустить | s — пропустить | q — выход: '
    read -r action < "$TTY" || action=q
    case "$action" in
      s|S)
        say 'Пропущено.'
        skipped=$((skipped+1))
        continue
        ;;
      q|Q)
        say "Мультитест остановлен."
        break
        ;;
    esac

    rc=0
    run_interruptible "$num" || rc=$?
    case "$rc" in
      0)
        passed=$((passed+1))
        ;;
      130)
        skipped=$((skipped+1))
        ;;
      *)
        failed=$((failed+1))
        warn "Тест $num завершился с rc=$rc"
        ;;
    esac
  done

  echo
  printf '%sИтог:%s PASS=%s FAIL=%s SKIP=%s\n'     "$C_GREEN" "$C_RESET" "$passed" "$failed" "$skipped"
  (( failed == 0 ))
}

menu(){
  local choice rc
  while true; do
    echo
    printf '%s============================================================%s\n' "$C_CYAN" "$C_RESET"
    say 'REMNANODE NEXT — SERVER MULTITEST'
    say "Derived from: $SOURCE_REPO @ $SOURCE_REF"
    printf '%s============================================================%s\n' "$C_CYAN" "$C_RESET"
    print_list
    say ' 0) Назад'
    echo
    printf 'Выбор: '
    read -r choice < "$TTY" || choice=0
    case "$choice" in
      1|2|3|4|5|6|7|8|9|10|11|12|13|14)
        rc=0
        run_interruptible "$choice" || rc=$?
        (( rc == 0 || rc == 130 )) || warn "Тест завершился с rc=$rc"
        pause
        ;;
      99)
        run_all || true
        pause
        ;;
      0|'')
        return 0
        ;;
      *)
        warn 'Неверный выбор.'
        ;;
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
