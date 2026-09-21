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
# - YABS is disk-only (-ign): iperf/Geekbench/network-info are covered elsewhere.
# - NextTrace full binary v1.7.3 is downloaded from the official GitHub release,
#   pinned by upstream SHA256, and cached outside PATH for MTR/PMTU/Globalping tests.
# - all/99 runs every test automatically without per-test Enter prompts.

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

NETWORK_BENCH_URL="https://speed.cloudflare.com/__down?bytes=100000000"

NEXTTRACE_VERSION="v1.7.3"
NEXTTRACE_AMD64_SHA256="aa75440fcdee46c16d941f48f9dabee1eb4c35bea6b739b0960fcf8307088c29"
NEXTTRACE_ARM64_SHA256="4fbf436e2d4737e4a491e71ce3cd140a7a268d43ec94fb9ac9497aec7eda080e"
NEXTTRACE_BASE_URL="https://github.com/nxtrace/NTrace-core/releases/download/${NEXTTRACE_VERSION}"
NEXTTRACE_TOOL_DIR="/usr/local/libexec/remnanode-next-tools"
NEXTTRACE_BIN=""

REPORT_ROOT="${MULTITEST_REPORT_DIR:-/var/log/remnanode-next/multitest}"

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

run_external_script_timeout(){
  local seconds="$1" name="$2" url="$3" expected_blob="${4:-}"
  shift 4
  local tmp rc=0
  need_cmd timeout coreutils || return 1
  tmp="$(mktemp "/tmp/remna-multitest.XXXXXX.sh")"
  echo
  printf '%s================ %s ================%s\n' "$C_CYAN" "$name" "$C_RESET"
  say "Execution timeout: ${seconds}s"
  if [[ -n "$expected_blob" ]]; then
    say "Entry script pinned: $expected_blob"
  else
    warn 'Этот внешний entry script не имеет закреплённого upstream SHA.'
  fi
  if download_external_script "$name" "$url" "$tmp" "$expected_blob"; then
    set +e
    timeout --signal=INT --kill-after=30 "${seconds}s" bash "$tmp" "$@"
    rc=$?
    set -e
    if (( rc == 124 )); then
      warn "$name превысил лимит ${seconds}s и остановлен."
    fi
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

ensure_nexttrace(){
  need_cmd curl curl ca-certificates
  need_cmd sha256sum coreutils
  need_cmd timeout coreutils

  local arch asset expected tmp got
  case "$(uname -m)" in
    x86_64|amd64)
      arch="amd64"
      expected="$NEXTTRACE_AMD64_SHA256"
      ;;
    aarch64|arm64)
      arch="arm64"
      expected="$NEXTTRACE_ARM64_SHA256"
      ;;
    *)
      fail "NextTrace: неподдерживаемая архитектура $(uname -m); поддерживаются amd64/arm64."
      return 1
      ;;
  esac

  asset="nexttrace_linux_${arch}"
  NEXTTRACE_BIN="$NEXTTRACE_TOOL_DIR/nexttrace-${NEXTTRACE_VERSION}-${arch}"
  install -d -m 0755 "$NEXTTRACE_TOOL_DIR"

  if [[ -x "$NEXTTRACE_BIN" ]]; then
    got="$(sha256sum "$NEXTTRACE_BIN" | awk '{print $1}')"
    if [[ "$got" == "$expected" ]]; then
      return 0
    fi
    warn "Cached NextTrace checksum mismatch; файл будет заменён."
  fi

  tmp="$(mktemp "/tmp/nexttrace.XXXXXX")"
  if ! curl -fsSL --proto '=https' --tlsv1.2       --connect-timeout 10 --max-time 180 --retry 2       -o "$tmp" "$NEXTTRACE_BASE_URL/$asset"; then
    rm -f "$tmp"
    fail "Не удалось скачать NextTrace $NEXTTRACE_VERSION ($arch)."
    return 1
  fi

  got="$(sha256sum "$tmp" | awk '{print $1}')"
  if [[ "$got" != "$expected" ]]; then
    rm -f "$tmp"
    fail "NextTrace SHA256 mismatch: $got != $expected"
    return 1
  fi

  install -m 0755 "$tmp" "$NEXTTRACE_BIN"
  rm -f "$tmp"
  say "NextTrace $NEXTTRACE_VERSION установлен в $NEXTTRACE_BIN"
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


test_yabs(){
  # Сеть отдельно измеряется iPerf3 + Cloudflare, CPU — sysbench.
  # YABS оставляем только для fio disk I/O: -i отключает iperf, -g Geekbench, -n network info.
  run_external_script_timeout 420 "YABS — disk fio only" "$YABS_URL" "$YABS_BLOB_SHA" -ign
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


test_network_100mb(){
  need_cmd curl curl ca-certificates
  local result bytes speed seconds
  say 'Network Bench: HTTPS download 100 MB via Cloudflare speed endpoint'
  result="$(curl -4 -fsSL --proto '=https' --tlsv1.2     --connect-timeout 10 --max-time 180     -o /dev/null     -w '%{size_download} %{speed_download} %{time_total}'     "$NETWORK_BENCH_URL")" || return 1
  IFS=' ' read -r bytes speed seconds <<<"$result"
  awk -v b="$bytes" -v s="$speed" -v t="$seconds" '
    BEGIN {
      printf "Downloaded: %.2f MB\n", b / 1000000
      printf "Average:    %.2f Mbit/s\n", s * 8 / 1000000
      printf "Time:       %.2f s\n", t
    }
  '
}




test_nexttrace_mtr(){
  ensure_nexttrace
  say 'NextTrace MTR: TCP/443, 10 probes/hop, wide report with route/ASN/geo'
  timeout 180 "$NEXTTRACE_BIN" -w --tcp --port 443 -q 10 --language en --no-color 1.1.1.1
}

test_nexttrace_mtu(){
  ensure_nexttrace
  say 'NextTrace Path MTU: UDP PMTU discovery to 1.1.1.1'
  timeout 120 "$NEXTTRACE_BIN" --mtu --language en --no-color 1.1.1.1
}

node_test_target(){
  local target=""
  if [[ -s /opt/remnanode/.node_domain ]]; then
    target="$(tr -d '[:space:]' </opt/remnanode/.node_domain)"
  fi
  if [[ -z "$target" ]]; then
    target="${NODE_TEST_TARGET:-}"
  fi
  [[ -n "$target" ]] || {
    fail 'Globalping: не найден /opt/remnanode/.node_domain. Можно задать NODE_TEST_TARGET.'
    return 1
  }
  printf '%s\n' "$target"
}

test_nexttrace_globalping(){
  ensure_nexttrace
  local target from rc=0 ok_count=0
  target="$(node_test_target)" || return 1
  say "Globalping: внешние traceroute к ноде $target"
  say 'Anonymous Globalping limit: до 250 tests/hour; GLOBALPING_TOKEN может увеличить лимит.'

  for from in Europe "North America" Asia; do
    echo
    printf '%s--- from %s ---%s\n' "$C_CYAN" "$from" "$C_RESET"
    if timeout 120 "$NEXTTRACE_BIN" "$target" --from "$from" --tcp --port 443 --language en --no-color; then
      ok_count=$((ok_count+1))
    else
      warn "Globalping from $from завершился ошибкой."
      rc=1
    fi
  done

  (( ok_count > 0 )) || return 1
  return "$rc"
}

run_one(){
  case "${1:-}" in
    1) test_ip_region ;;
    2) test_censor_geoblock ;;
    3) test_censor_dpi ;;
    4) test_iperf_ru ;;
    5) test_yabs ;;
    6) test_geo_unlock ;;
    7) test_ipquality ;;
    8) test_sysbench_cpu ;;
    9) test_network_100mb ;;
    10) test_nexttrace_mtr ;;
    11) test_nexttrace_mtu ;;
    12) test_nexttrace_globalping ;;
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
 5) YABS — disk fio only
 6) Geo/Media Unlock — RegionRestrictionCheck
 7) IPQuality — ASN / risk / blacklist / media / mail
 8) sysbench CPU
 9) Network Bench — HTTPS 100MB
10) NextTrace Route/MTR — loss/jitter/ASN/geo
11) NextTrace Path MTU — UDP PMTU
12) NextTrace Globalping — внешние TCP/443 точки → эта нода
98) Анализ последнего прогона
99) Мультитест: все тесты автоматически
EOF
}

ensure_report_root(){
  install -d -m 0755 "$REPORT_ROOT"
}

latest_report_dir(){
  local p=""
  [[ -r "$REPORT_ROOT/latest.path" ]] && p="$(cat "$REPORT_ROOT/latest.path" 2>/dev/null || true)"
  [[ -n "$p" && -d "$p" ]] || return 1
  printf '%s\n' "$p"
}

report_key_metrics(){
  local dir="$1"
  echo '=== KEY METRICS / SIGNALS ==='

  if [[ -f "$dir/01-ip-region.log" ]]; then
    grep -aE '"(ip|city|region|country_name|country|org|asn)"[[:space:]]*:' "$dir/01-ip-region.log" | head -20 || true
  fi

  if [[ -f "$dir/04-iperf-ru.log" ]]; then
    echo
    echo '[iPerf3 RU]'
    grep -aE 'Mbits/sec|Gbits/sec|Mbit/s|Gbit/s|Location|Provider' "$dir/04-iperf-ru.log" | tail -30 || true
  fi

  if [[ -f "$dir/05-yabs-disk.log" ]]; then
    echo
    echo '[Disk fio]'
    grep -aE 'fio Disk Speed|Block Size|Read|Write|Total|IOPS|MB/s|GB/s' "$dir/05-yabs-disk.log" | tail -35 || true
  fi

  if [[ -f "$dir/07-ipquality.log" ]]; then
    echo
    echo '[IP quality / unlock]'
    grep -aiE 'ASN|Country|Location|Risk|Blacklist|Netflix|YouTube|ChatGPT|TikTok|Disney|Mail|Proxy|Hosting|Datacenter|Abuse' "$dir/07-ipquality.log" | tail -50 || true
  fi

  if [[ -f "$dir/08-sysbench-cpu.log" ]]; then
    echo
    echo '[CPU]'
    grep -aE 'events per second|total time|total number of events' "$dir/08-sysbench-cpu.log" | tail -10 || true
  fi

  if [[ -f "$dir/09-network-bench.log" ]]; then
    echo
    echo '[Cloudflare 100MB]'
    grep -aE 'Downloaded:|Average:|Time:' "$dir/09-network-bench.log" | tail -10 || true
  fi

  if [[ -f "$dir/10-nexttrace-mtr.log" ]]; then
    echo
    echo '[NextTrace MTR]'
    grep -aE 'Loss|Avg|Best|Wrst|StDev|AS[0-9]|ms' "$dir/10-nexttrace-mtr.log" | tail -35 || true
  fi

  if [[ -f "$dir/11-nexttrace-mtu.log" ]]; then
    echo
    echo '[Path MTU]'
    grep -aiE 'MTU|PMTU|payload|fragment' "$dir/11-nexttrace-mtu.log" | tail -20 || true
  fi

  if [[ -f "$dir/12-nexttrace-globalping.log" ]]; then
    echo
    echo '[External TCP/443]'
    grep -aE '^--- from |ms|AS[0-9]|Trace|reached|unreachable|timeout' "$dir/12-nexttrace-globalping.log" | tail -50 || true
  fi
}

generate_report(){
  local dir="$1" summary="$dir/summary.tsv" analysis="$dir/analysis.txt" ai="$dir/AI_REPORT.txt"
  local pass fail skip total speed

  pass="$(awk -F '\t' 'NR>1 && $3=="PASS"{n++} END{print n+0}' "$summary")"
  fail="$(awk -F '\t' 'NR>1 && $3=="FAIL"{n++} END{print n+0}' "$summary")"
  skip="$(awk -F '\t' 'NR>1 && $3=="SKIP"{n++} END{print n+0}' "$summary")"
  total="$(awk -F '\t' 'NR>1{n++} END{print n+0}' "$summary")"

  {
    echo '======================================================================'
    echo ' REMNANODE NEXT — MULTITEST ANALYSIS'
    echo '======================================================================'
    printf 'Host: %s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'UTC:  %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
    printf 'Run:  %s\n' "$dir"
    printf 'Result: PASS=%s FAIL=%s SKIP=%s TOTAL=%s\n' "$pass" "$fail" "$skip" "$total"
    echo
    echo '=== TEST STATUS ==='
    awk -F '\t' 'NR>1{printf "%-4s %-52s %-6s %5ss rc=%s\n",$1,$2,$3,$4,$5}' "$summary"

    echo
    echo '=== AUTOMATIC FINDINGS ==='
    if (( fail > 0 )); then
      echo '[WARN] Есть упавшие тесты:'
      awk -F '\t' 'NR>1 && $3=="FAIL"{printf "  - #%s %s (rc=%s)\n",$1,$2,$5}' "$summary"
    else
      echo '[OK] Все запущенные тесты завершились без ошибки.'
    fi

    if (( skip > 0 )); then
      printf '[INFO] Пропущено тестов: %s\n' "$skip"
    fi

    speed="$(awk '/Average:[[:space:]]+[0-9.]+ Mbit\/s/{print $2; exit}' "$dir/09-network-bench.log" 2>/dev/null || true)"
    if [[ "$speed" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      awk -v s="$speed" 'BEGIN{
        if (s < 20) printf "[WARN] Cloudflare download %.2f Mbit/s — очень низко для VPN-ноды; проверь канал/шейпинг.\n",s;
        else if (s < 50) printf "[WARN] Cloudflare download %.2f Mbit/s — низковато; сравни с тарифом и iPerf.\n",s;
        else printf "[INFO] Cloudflare download %.2f Mbit/s.\n",s;
      }'
    fi

    echo
    report_key_metrics "$dir"
    echo
    echo '=== INTERPRETATION RULE ==='
    echo 'FAIL означает ошибку запуска/timeout/ненулевой exit code, а не автоматически плохое качество ноды.'
    echo 'Сетевые скорости, geo/risk базы и маршруты нужно оценивать вместе и относительно тарифа/локации.'
  } >"$analysis"

  {
    echo '# REMNANODE NEXT MULTITEST — AI REPORT'
    printf 'host: %s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'utc: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
    printf 'result: PASS=%s FAIL=%s SKIP=%s TOTAL=%s\n' "$pass" "$fail" "$skip" "$total"
    echo
    echo '## TEST STATUS'
    cat "$summary"
    echo
    echo '## KEY METRICS'
    report_key_metrics "$dir"
    echo
    echo '## FAILURES / TIMEOUTS'
    grep -aE '\[ERROR\]|\[WARN\]|timeout|timed out|превысил лимит|rc=' "$dir"/*.log 2>/dev/null | tail -120 || true
    echo
    echo '## REQUEST'
    echo 'Проанализируй результаты RemnaNode: выдели проблемы, вероятные причины, приоритет проверки и что выглядит нормальным. Не делай вывод только по одному внешнему geo/risk источнику.'
  } >"$ai"

  cp -f "$analysis" "$REPORT_ROOT/latest-analysis.txt"
  cp -f "$ai" "$REPORT_ROOT/latest-AI_REPORT.txt"
}

show_latest_analysis(){
  ensure_report_root
  local dir
  dir="$(latest_report_dir)" || {
    fail 'Нет сохранённых прогонов. Сначала запусти multitest all.'
    return 1
  }
  generate_report "$dir"
  cat "$dir/analysis.txt"
}

show_latest_report(){
  ensure_report_root
  local dir
  dir="$(latest_report_dir)" || {
    fail 'Нет сохранённых прогонов. Сначала запусти multitest all.'
    return 1
  }
  generate_report "$dir"
  printf 'Run directory: %s\n' "$dir"
  printf 'Analysis:      %s/analysis.txt\n' "$dir"
  printf 'AI report:     %s/AI_REPORT.txt\n' "$dir"
  printf 'Raw logs:      %s/*.log\n' "$dir"
}

run_all(){
  local names=(
    "IP Region"
    "Censorcheck — проверка геоблока"
    "Censorcheck — DPI"
    "iPerf3 — российские серверы"
    "YABS — disk fio only"
    "Geo/Media Unlock — RegionRestrictionCheck"
    "IPQuality"
    "sysbench CPU"
    "Network Bench — HTTPS 100MB"
    "NextTrace Route/MTR"
    "NextTrace Path MTU"
    "NextTrace Globalping"
  )
  local slugs=(
    "ip-region"
    "censor-geoblock"
    "censor-dpi"
    "iperf-ru"
    "yabs-disk"
    "geo-unlock"
    "ipquality"
    "sysbench-cpu"
    "network-bench"
    "nexttrace-mtr"
    "nexttrace-mtu"
    "nexttrace-globalping"
  )
  local total="${#names[@]}" i num rc status started ended duration
  local passed=0 failed=0 skipped=0
  local run_id run_dir summary logfile

  ensure_report_root
  run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
  run_dir="$REPORT_ROOT/$run_id"
  install -d -m 0755 "$run_dir"
  summary="$run_dir/summary.tsv"
  printf 'test\tname\tstatus\tduration_sec\trc\n' >"$summary"

  {
    printf 'host=%s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'utc_start=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'kernel=%s\n' "$(uname -srmo)"
    printf 'tester_source=%s@%s\n' "$SOURCE_REPO" "$SOURCE_REF"
  } >"$run_dir/meta.txt"

  say 'Автоматический режим: все тесты идут подряд без подтверждений.'
  printf '%sCtrl+C во время теста — пропустить только текущий и перейти дальше.%s\n' "$C_GRAY" "$C_RESET"
  printf 'Отчёт: %s\n' "$run_dir"

  for ((i=0; i<total; i++)); do
    num=$((i+1))
    logfile="$(printf '%s/%02d-%s.log' "$run_dir" "$num" "${slugs[$i]}")"
    echo
    printf '%s============ [%s/%s] %s ============ %s\n'       "$C_CYAN" "$num" "$total" "${names[$i]}" "$C_RESET"

    started="$(date +%s)"
    set +e
    run_interruptible "$num" 2>&1 | tee "$logfile"
    rc=${PIPESTATUS[0]}
    set -e
    ended="$(date +%s)"
    duration=$((ended-started))

    case "$rc" in
      0)
        status=PASS
        passed=$((passed+1))
        ;;
      130)
        status=SKIP
        skipped=$((skipped+1))
        ;;
      *)
        status=FAIL
        failed=$((failed+1))
        warn "Тест $num завершился с rc=$rc"
        ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$num" "${names[$i]}" "$status" "$duration" "$rc" >>"$summary"
  done

  printf '%s\n' "$run_dir" >"$REPORT_ROOT/latest.path"
  generate_report "$run_dir"

  echo
  printf '%sИтог:%s PASS=%s FAIL=%s SKIP=%s TOTAL=%s\n'     "$C_GREEN" "$C_RESET" "$passed" "$failed" "$skipped" "$total"
  printf 'Analysis:  %s/analysis.txt\n' "$run_dir"
  printf 'AI report: %s/AI_REPORT.txt\n' "$run_dir"
  printf 'Команда:   sudo remnanode-next multitest analyze\n'
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
      1|2|3|4|5|6|7|8|9|10|11|12)
        rc=0
        run_interruptible "$choice" || rc=$?
        (( rc == 0 || rc == 130 )) || warn "Тест завершился с rc=$rc"
        pause
        ;;
      98)
        show_latest_analysis || true
        pause
        ;;
      99)
        run_all || true
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
  server-multitest.sh analyze
  server-multitest.sh report
  server-multitest.sh 1..12
EOF
}

main(){
  case "${1:-menu}" in
    list) print_list ;;
    -h|--help|help) usage ;;
    menu|'') need_root; menu ;;
    all|99) need_root; run_all ;;
    analyze) need_root; show_latest_analysis ;;
    report) need_root; show_latest_report ;;
    1|2|3|4|5|6|7|8|9|10|11|12) need_root; run_interruptible "$1" ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
