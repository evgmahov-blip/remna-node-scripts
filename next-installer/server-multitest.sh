#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# REMNANODE NEXT — server multitest
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
NETWORK_BENCH_FALLBACK_URL="https://speed.cloudflare.com/__down?bytes=50000000"
NETWORK_BENCH_REFERER="https://speed.cloudflare.com/"

NEXTTRACE_VERSION="v1.7.3"
NEXTTRACE_AMD64_SHA256="aa75440fcdee46c16d941f48f9dabee1eb4c35bea6b739b0960fcf8307088c29"
NEXTTRACE_ARM64_SHA256="4fbf436e2d4737e4a491e71ce3cd140a7a268d43ec94fb9ac9497aec7eda080e"
NEXTTRACE_BASE_URL="https://github.com/nxtrace/NTrace-core/releases/download/${NEXTTRACE_VERSION}"
NEXTTRACE_TOOL_DIR="/usr/local/libexec/remnanode-next-tools"
NEXTTRACE_BIN=""

REPORT_ROOT="${MULTITEST_REPORT_DIR:-/var/log/remnanode-next/multitest}"
MULTITEST_NO_INSTALL="${MULTITEST_NO_INSTALL:-0}"

TTY=/dev/tty
[[ -r "$TTY" ]] || TTY=/dev/stdin

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
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
    if [[ "$MULTITEST_NO_INSTALL" == "1" ]]; then
      fail "Команда $cmd отсутствует; machine mode не устанавливает пакеты."
      return 1
    fi
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
  say "Max runtime: ${seconds}s"
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

  if [[ -x "$NEXTTRACE_BIN" ]]; then
    got="$(sha256sum "$NEXTTRACE_BIN" | awk '{print $1}')"
    if [[ "$got" == "$expected" ]]; then
      return 0
    fi
    if [[ "$MULTITEST_NO_INSTALL" == "1" ]]; then
      fail "Cached NextTrace checksum mismatch; machine mode не заменяет бинарники."
      return 1
    fi
    warn "Cached NextTrace checksum mismatch; файл будет заменён."
  fi

  if [[ "$MULTITEST_NO_INSTALL" == "1" ]]; then
    fail "NextTrace $NEXTTRACE_VERSION не установлен; machine mode не устанавливает бинарники."
    return 1
  fi

  install -d -m 0755 "$NEXTTRACE_TOOL_DIR"
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

classify_ai_http(){
  local http="$1" body="$2"

  if grep -Eiq 'unsupported[_ -]country|country[^[:alnum:]]+(is )?not supported|region[^[:alnum:]]+(is )?not supported|not available in (your|this) (country|region)|geo.?block' "$body" 2>/dev/null; then
    printf 'GEO_BLOCK'
    return 1
  fi

  case "$http" in
    200|201|202|204|301|302|303|307|308)
      printf 'REACHABLE'
      return 0
      ;;
    400|401|403)
      if [[ "$http" == "401" ]] || grep -Eiq 'api.?key|authentication|authorization|unauthenticated|credential|bearer|unregistered caller|established identity' "$body" 2>/dev/null; then
        printf 'REACHABLE_AUTH'
        return 0
      fi
      printf 'HTTP_%s_DENIED' "$http"
      return 1
      ;;
    405)
      printf 'REACHABLE_METHOD'
      return 0
      ;;
    429)
      printf 'REACHABLE_RATE_LIMIT'
      return 0
      ;;
    451)
      printf 'POLICY_BLOCK'
      return 1
      ;;
    5??)
      printf 'SERVICE_ERROR_%s' "$http"
      return 1
      ;;
    000|'')
      printf 'NO_HTTP'
      return 1
      ;;
    *)
      printf 'HTTP_%s' "$http"
      return 1
      ;;
  esac
}

test_ai_access(){
  need_cmd curl curl ca-certificates

  local probes=(
    "OpenAI|GET|https://api.openai.com/v1/models"
    "Anthropic|GET|https://api.anthropic.com/v1/models"
    "Gemini|GET|https://generativelanguage.googleapis.com/v1beta/models"
    "Mistral|GET|https://api.mistral.ai/v1/models"
    "xAI/Grok|GET|https://api.x.ai/v1/models"
    "Perplexity|POST|https://api.perplexity.ai/chat/completions"
  )
  local entry name method url body err meta rc http remote_ip connect_time tls_time state state_rc
  local reachable=0 failed=0 total=0
  local curl_args=()

  printf '%s================ AI Access ================%s\n' "$C_CYAN" "$C_RESET"
  say 'Без API-ключей и без расхода токенов: проверяются DNS/TCP/TLS/HTTP и ожидаемые auth-ответы.'

  for entry in "${probes[@]}"; do
    IFS='|' read -r name method url <<<"$entry"
    body="$(mktemp "/tmp/remna-ai-body.XXXXXX")"
    err="$(mktemp "/tmp/remna-ai-err.XXXXXX")"
    curl_args=(
      -4 -sS
      --proto '=https'
      --tlsv1.2
      --connect-timeout 8
      --max-time 15
      -o "$body"
      -w '%{http_code}|%{remote_ip}|%{time_connect}|%{time_appconnect}'
    )
    if [[ "$method" == "POST" ]]; then
      curl_args+=(-H 'Content-Type: application/json' -X POST --data '{}')
    fi

    if meta="$(curl "${curl_args[@]}" "$url" 2>"$err")"; then
      rc=0
    else
      rc=$?
    fi
    total=$((total+1))

    if (( rc != 0 )); then
      case "$rc" in
        6) state='DNS_FAIL' ;;
        7) state='CONNECT_FAIL' ;;
        28) state='TIMEOUT' ;;
        35|51|58|60) state='TLS_FAIL' ;;
        *) state="CURL_FAIL_$rc" ;;
      esac
      failed=$((failed+1))
      printf '%-11s %s%-20s%s rc=%s\n' "$name" "$C_RED" "$state" "$C_RESET" "$rc"
      if [[ -s "$err" ]]; then
        printf '             %s%s%s\n' "$C_GRAY" "$(head -c 220 "$err" | tr '\n\r' '  ')" "$C_RESET"
      fi
      rm -f "$body" "$err"
      continue
    fi

    IFS='|' read -r http remote_ip connect_time tls_time <<<"$meta"
    state_rc=0
    state="$(classify_ai_http "$http" "$body")" || state_rc=$?
    if (( state_rc == 0 )); then
      reachable=$((reachable+1))
      printf '%-11s %s%-20s%s HTTP=%s IP=%s connect=%ss tls=%ss\n' "$name" "$C_GREEN" "$state" "$C_RESET" "$http" "${remote_ip:-?}" "${connect_time:-?}" "${tls_time:-?}"
    else
      failed=$((failed+1))
      printf '%-11s %s%-20s%s HTTP=%s IP=%s connect=%ss tls=%ss\n' "$name" "$C_RED" "$state" "$C_RESET" "$http" "${remote_ip:-?}" "${connect_time:-?}" "${tls_time:-?}"
    fi
    rm -f "$body" "$err"
  done

  printf 'AI_SUMMARY: reachable=%s failed=%s total=%s\n' "$reachable" "$failed" "$total"
  (( failed == 0 ))
}

test_ipquality(){
  need_cmd curl curl ca-certificates
  need_cmd jq jq
  need_cmd timeout coreutils

  local script json stderr rc=0
  script="$(mktemp "/tmp/remna-ipquality.XXXXXX.sh")"
  json="$(mktemp "/tmp/remna-ipquality.XXXXXX.json")"
  stderr="$(mktemp "/tmp/remna-ipquality.XXXXXX.err")"
  rm -f "$json"

  printf '%s================ IPQuality ================%s\n' "$C_CYAN" "$C_RESET"
  if ! download_external_script "IPQuality" "$IPQUALITY_URL" "$script" "$IPQUALITY_BLOB_SHA"; then
    rm -f "$script" "$json" "$stderr"
    return 1
  fi

  # Upstream returns rc=1 on IPv4-only hosts because its final IPv6 conditional
  # becomes the shell exit status. Its documented JSON output file is authoritative.
  set +e
  timeout --signal=INT --kill-after=15 120s \
    bash "$script" -l ru -n -p -o "$json" >/dev/null 2>"$stderr"
  rc=$?
  set -e

  if (( rc == 0 || rc == 1 )) && [[ -s "$json" ]] && \
     jq -e '(.Info.ASN != null) and ((.Score | type) == "object") and ((.Factor.Proxy | type) == "object") and ((.Media | type) == "object") and ((.Mail.DNSBlacklist | type) == "object")' \
       "$json" >/dev/null 2>&1; then
    if (( rc == 1 )); then
      warn "IPQuality вернул rc=1, но полный JSON валиден; принимаю результат (upstream IPv4-only exit-status quirk)."
    fi
  else
    fail "IPQuality не создал валидный JSON (rc=$rc)."
    if [[ -s "$stderr" ]]; then
      printf '%sДиагностика upstream (последние строки):%s\n' "$C_GRAY" "$C_RESET" >&2
      tail -n 8 "$stderr" >&2 || true
    fi
    rm -f "$script" "$json" "$stderr"
    return 1
  fi

  jq -r '
    "ASN: " + (.Info.ASN // "?"),
    "Region: " + (.Info.Region.Code // "?") + " " + (.Info.Region.Name // ""),
    "Usage: " + ([.Type.Usage[]?] | unique | join(", ")),
    "Risk: IP2Location=" + (.Score.IP2LOCATION // "?") +
      " AbuseIPDB=" + (.Score.AbuseIPDB // "?") +
      " Scamalytics=" + (.Score.SCAMALYTICS // "?"),
    "Proxy flags: " + ([.Factor.Proxy | to_entries[] | select(.value == true) | .key] |
      if length == 0 then "none" else join(",") end),
    "Media: " + ([.Media | to_entries[] |
      (.key + "=" + (.value.Status // "?") + "/" + (.value.Region // "-"))] | join(" ")),
    "DNSBL: clean=" + ((.Mail.DNSBlacklist.Clean // "?")|tostring) +
      " marked=" + ((.Mail.DNSBlacklist.Marked // "?")|tostring) +
      " blacklisted=" + ((.Mail.DNSBlacklist.Blacklisted // "?")|tostring)
  ' "$json"

  rm -f "$script" "$json" "$stderr"
  return 0
}
test_sysbench_cpu(){
  need_cmd sysbench sysbench
  need_cmd nproc coreutils

  local threads
  threads="$(nproc)"
  [[ "$threads" =~ ^[0-9]+$ ]] || threads=1

  echo 'CPU single-thread:'
  sysbench cpu --threads=1 --time=10 --cpu-max-prime=20000 run

  if (( threads > 1 )); then
    echo
    printf 'CPU all-thread (%s threads):\n' "$threads"
    sysbench cpu --threads="$threads" --time=10 --cpu-max-prime=20000 run
  fi
}


test_network_100mb(){
  need_cmd curl curl ca-certificates
  local result bytes speed seconds url label rc=1

  say 'Network Bench: Cloudflare HTTPS download'
  say 'Using Referer: https://speed.cloudflare.com/'

  for label in "100 MB" "50 MB fallback"; do
    if [[ "$label" == "100 MB" ]]; then
      url="$NETWORK_BENCH_URL"
    else
      url="$NETWORK_BENCH_FALLBACK_URL"
    fi

    printf 'Attempt: %s\n' "$label"
    set +e
    result="$(curl -4 -fsSL --proto '=https' --tlsv1.2       -H "Referer: $NETWORK_BENCH_REFERER"       -A 'REMNANODE-NEXT-NetworkBench/1.0'       --connect-timeout 10 --max-time 180 --retry 1 --retry-delay 1       -o /dev/null       -w '%{size_download} %{speed_download} %{time_total}'       "$url")"
    rc=$?
    set -e

    if (( rc == 0 )); then
      IFS=' ' read -r bytes speed seconds <<<"$result"
      if [[ "$bytes" =~ ^[0-9]+([.][0-9]+)?$ && "$speed" =~ ^[0-9]+([.][0-9]+)?$ && "$seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        awk -v b="$bytes" -v s="$speed" -v t="$seconds" -v src="$label" '
          BEGIN {
            printf "Source:     Cloudflare %s\n", src
            printf "Downloaded: %.2f MB\n", b / 1000000
            printf "Average:    %.2f Mbit/s\n", s * 8 / 1000000
            printf "Time:       %.2f s\n", t
          }
        '
        return 0
      fi
    fi

    warn "Cloudflare $label attempt failed (curl rc=$rc)."
  done

  fail 'Cloudflare network bench failed for both 100MB and 50MB endpoints.'
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
    13) test_ai_access ;;
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
13) AI Access — OpenAI / Claude / Gemini / Mistral / Grok / Perplexity
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
    sed -E 's/\\x1B\\[[0-9;]*[mK]//g' "$dir/04-iperf-ru.log" \
      | grep -aE 'Server[[:space:]]+Download[[:space:]]+Upload[[:space:]]+Ping|Mbps|Execution time' \
      | tail -30 || true
  fi

  if [[ -f "$dir/05-yabs-disk.log" ]]; then
    echo
    echo '[Disk fio]'
    grep -aE 'fio Disk Speed|Block Size|Read|Write|Total|IOPS|MB/s|GB/s' "$dir/05-yabs-disk.log" | tail -35 || true
  fi

  if [[ -f "$dir/07-ipquality.log" ]]; then
    echo
    echo '[IP quality / unlock]'
    grep -aE '^(ASN|Region|Usage|Risk|Proxy flags|Media|DNSBL):' "$dir/07-ipquality.log" | tail -20 || true
  fi

  if [[ -f "$dir/08-sysbench-cpu.log" ]]; then
    echo
    echo '[CPU]'
    grep -aE 'CPU single-thread:|CPU all-thread|events per second|total time|total number of events' "$dir/08-sysbench-cpu.log" | tail -20 || true
  fi

  if [[ -f "$dir/09-network-bench.log" ]]; then
    echo
    echo '[Cloudflare 100MB]'
    grep -aE 'Source:|Downloaded:|Average:|Time:' "$dir/09-network-bench.log" | tail -12 || true
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

  if [[ -f "$dir/13-ai-access.log" ]]; then
    echo
    echo '[AI access]'
    grep -aE '^(OpenAI|Anthropic|Gemini|Mistral|xAI/Grok|Perplexity|AI_SUMMARY):?' "$dir/13-ai-access.log" | tail -20 || true
  fi
}

print_node_scorecard(){
  local dir="$1"
  local summary
  local speed="" cpu_single="" cpu_all="" mtu="" blacklisted="" fail_count="" safe_mbps=""
  local ai_reachable="" ai_failed="" ai_total=""
  local at3="" at5=""

  summary="$dir/summary.tsv"

  [[ -f "$dir/09-network-bench.log" ]] &&     speed="$(awk '/Average:[[:space:]]+[0-9.]+ Mbit\/s/{print $2; exit}' "$dir/09-network-bench.log" 2>/dev/null || true)"

  if [[ -f "$dir/08-sysbench-cpu.log" ]]; then
    cpu_single="$(awk '
      /CPU single-thread:/ {mode="single"; next}
      /CPU all-thread/ {mode="all"; next}
      mode=="single" && /events per second:/ {print $4; exit}
    ' "$dir/08-sysbench-cpu.log" 2>/dev/null || true)"
    cpu_all="$(awk '
      /CPU all-thread/ {mode="all"; next}
      mode=="all" && /events per second:/ {print $4; exit}
    ' "$dir/08-sysbench-cpu.log" 2>/dev/null || true)"
  fi

  [[ -f "$dir/11-nexttrace-mtu.log" ]] &&     mtu="$(awk '/Path MTU:[[:space:]]*[0-9]+/{print $3; exit}' "$dir/11-nexttrace-mtu.log" 2>/dev/null || true)"

  [[ -f "$dir/07-ipquality.log" ]] &&     blacklisted="$(sed -nE 's/^DNSBL:.*blacklisted=([0-9]+).*/\1/p' "$dir/07-ipquality.log" | head -1)"

  if [[ -f "$dir/13-ai-access.log" ]]; then
    ai_reachable="$(sed -nE 's/^AI_SUMMARY: reachable=([0-9]+).*/\1/p' "$dir/13-ai-access.log" | tail -1)"
    ai_failed="$(sed -nE 's/^AI_SUMMARY:.* failed=([0-9]+).*/\1/p' "$dir/13-ai-access.log" | tail -1)"
    ai_total="$(sed -nE 's/^AI_SUMMARY:.* total=([0-9]+).*/\1/p' "$dir/13-ai-access.log" | tail -1)"
  fi

  [[ -f "$summary" ]] &&     fail_count="$(awk -F '\t' 'NR>1 && $3=="FAIL"{n++} END{print n+0}' "$summary")"

  echo '======================================================================'
  echo ' ИТОГ ПО НОДЕ'
  echo '======================================================================'
  printf 'FAIL:             %s\n' "${fail_count:-?}"
  printf 'Сеть:             %s\n' "$([[ -n "$speed" ]] && printf '%s Mbit/s' "$speed" || printf 'нет данных')"
  printf 'CPU single:       %s\n' "$([[ -n "$cpu_single" ]] && printf '%s events/s' "$cpu_single" || printf 'нет данных')"
  printf 'CPU all-thread:   %s\n' "$([[ -n "$cpu_all" ]] && printf '%s events/s' "$cpu_all" || printf 'нет данных')"
  printf 'MTU:              %s\n' "${mtu:-нет данных}"
  printf 'DNSBL blacklist:  %s\n' "${blacklisted:-нет данных}"
  if [[ -n "$ai_total" ]]; then
    printf 'AI APIs:          reachable=%s/%s failed=%s\n' "${ai_reachable:-0}" "$ai_total" "${ai_failed:-0}"
  else
    printf 'AI APIs:          нет данных\n'
  fi

  if [[ "$speed" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    safe_mbps="$(awk -v s="$speed" 'BEGIN{printf "%.1f", s*0.70}')"
    at3="$(awk -v s="$safe_mbps" 'BEGIN{print int(s/3)}')"
    at5="$(awk -v s="$safe_mbps" 'BEGIN{print int(s/5)}')"
    printf 'Рабочий бюджет:   %s Mbit/s (70%% измеренной скорости)\n' "$safe_mbps"
    printf 'XHTTP ориентир:   ~%s активных @3 Mbit/s / ~%s @5 Mbit/s\n' "$at3" "$at5"
  fi

  if [[ "$blacklisted" == "0" ]]; then
    echo 'IP reputation:    без DNSBL blacklist по текущему тесту'
  fi
  if [[ "$mtu" == "1500" ]]; then
    echo 'MTU:              нормальный для XHTTP/Hysteria2'
  fi
  echo '======================================================================'
}

generate_report(){
  local dir="$1"
  local summary analysis ai
  local pass fail skip total

  summary="$dir/summary.tsv"
  analysis="$dir/analysis.txt"
  ai="$dir/AI_REPORT.txt"

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
    print_node_scorecard "$dir"
    echo
    echo '=== ПРОБЛЕМЫ ==='
    if (( fail > 0 )); then
      awk -F '\t' 'NR>1 && $3=="FAIL"{printf "  #%s %s (rc=%s)\n",$1,$2,$5}' "$summary"
    else
      echo '  Нет.'
    fi
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

generate_json_report(){
  local dir mode out
  dir="$1"
  mode="${2:-human}"
  out="$dir/result.json"

  command -v python3 >/dev/null 2>&1 || {
    fail 'python3 отсутствует; JSON report не может быть построен.'
    return 1
  }

  python3 - "$dir" "$out" "$mode" <<'PY'
import csv
import json
import re
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])
out = Path(sys.argv[2])
mode = sys.argv[3]
summary = run_dir / "summary.tsv"

rows = []
with summary.open(encoding="utf-8", errors="replace") as fh:
    for row in csv.DictReader(fh, delimiter="\t"):
        rows.append({
            "test": int(row.get("test") or 0),
            "name": row.get("name") or "",
            "status": row.get("status") or "UNKNOWN",
            "duration_sec": int(float(row.get("duration_sec") or 0)),
            "rc": int(row.get("rc") or 0),
        })

def read(name):
    p = run_dir / name
    if not p.is_file():
        return ""
    return p.read_text(encoding="utf-8", errors="replace")

def first(pattern, text, cast=str, flags=0):
    m = re.search(pattern, text, flags)
    if not m:
        return None
    try:
        return cast(m.group(1))
    except Exception:
        return None

meta = {}
for line in read("meta.txt").splitlines():
    if "=" in line:
        k, v = line.split("=", 1)
        meta[k.strip()] = v.strip()

network = read("09-network-bench.log")
cpu = read("08-sysbench-cpu.log")
mtu_log = read("11-nexttrace-mtu.log")
ipq = read("07-ipquality.log")
ai_log = read("13-ai-access.log")

network_mbps = first(r"Average:\s+([0-9.]+) Mbit/s", network, float)
cpu_single = first(
    r"CPU single-thread:.*?events per second:\s*([0-9.]+)",
    cpu, float, re.S,
)
cpu_all = first(
    r"CPU all-thread.*?events per second:\s*([0-9.]+)",
    cpu, float, re.S,
)
path_mtu = first(r"Path MTU:\s*([0-9]+)", mtu_log, int)
dnsbl = first(r"DNSBL:.*blacklisted=([0-9]+)", ipq, int)

def prefixed(label):
    return first(rf"^{re.escape(label)}:\s*(.+)$", ipq, str, re.M)

ai_providers = []
for provider in ("OpenAI", "Anthropic", "Gemini", "Mistral", "xAI/Grok", "Perplexity"):
    m = re.search(
        rf"^{re.escape(provider)}\s+(\S+)\s+HTTP=([0-9]+)",
        ai_log,
        re.M,
    )
    if m:
        ai_providers.append({
            "provider": provider,
            "state": m.group(1),
            "http": int(m.group(2)),
        })

ai_reachable = first(r"AI_SUMMARY:\s*reachable=([0-9]+)", ai_log, int)
ai_failed = first(r"AI_SUMMARY:.*failed=([0-9]+)", ai_log, int)
ai_total = first(r"AI_SUMMARY:.*total=([0-9]+)", ai_log, int)

passed = sum(1 for r in rows if r["status"] == "PASS")
failed = sum(1 for r in rows if r["status"] == "FAIL")
skipped = sum(1 for r in rows if r["status"] == "SKIP")
duration = sum(r["duration_sec"] for r in rows)

issues = [
    {
        "test": r["test"],
        "name": r["name"],
        "status": r["status"],
        "rc": r["rc"],
    }
    for r in rows
    if r["status"] != "PASS"
]

working_budget = round(network_mbps * 0.70, 1) if network_mbps is not None else None
xhttp_3 = int(working_budget / 3) if working_budget is not None else None
xhttp_5 = int(working_budget / 5) if working_budget is not None else None

conclusions = []
if failed:
    bad = ", ".join(f"#{x['test']} {x['name']}" for x in issues if x["status"] == "FAIL")
    conclusions.append(f"FAIL={failed}: {bad}")
elif skipped:
    conclusions.append(f"FAIL=0, но SKIP={skipped}; пропущенные тесты требуют отдельной проверки.")
else:
    conclusions.append(f"Все {len(rows)} тестов завершились без FAIL/SKIP.")

if network_mbps is not None:
    conclusions.append(
        f"HTTPS {network_mbps:.1f} Mbit/s; рабочий бюджет ~{working_budget:.1f} Mbit/s; "
        f"ориентир XHTTP ~{xhttp_3} @3 Mbit/s / ~{xhttp_5} @5 Mbit/s."
    )
if cpu_single is not None or cpu_all is not None:
    conclusions.append(
        "CPU: single="
        + (f"{cpu_single:.1f}" if cpu_single is not None else "n/a")
        + " events/s; all-thread="
        + (f"{cpu_all:.1f}" if cpu_all is not None else "n/a")
        + " events/s."
    )
if path_mtu is not None:
    conclusions.append(
        "Path MTU 1500."
        if path_mtu == 1500
        else f"Path MTU {path_mtu}; ниже 1500 — проверь overhead/фрагментацию."
    )
if dnsbl is not None:
    conclusions.append(
        "DNSBL: blacklist не обнаружен."
        if dnsbl == 0
        else f"DNSBL: blacklisted={dnsbl}; репутацию IP стоит проверить."
    )
if ai_total is not None:
    conclusions.append(
        f"AI API: reachable={ai_reachable or 0}/{ai_total}, failed={ai_failed or 0}."
    )

overall = "PASS" if failed == 0 and skipped == 0 else "WARN"
payload = {
    "schema": "remnanode.multitest.v1",
    "overall_status": overall,
    "execution_mode": mode,
    "host": meta.get("host"),
    "utc_start": meta.get("utc_start"),
    "duration_sec": duration,
    "counts": {
        "pass": passed,
        "fail": failed,
        "skip": skipped,
        "total": len(rows),
    },
    "tests": rows,
    "metrics": {
        "network_mbps": network_mbps,
        "working_budget_mbps": working_budget,
        "xhttp_active_at_3mbps": xhttp_3,
        "xhttp_active_at_5mbps": xhttp_5,
        "cpu_single_events_sec": cpu_single,
        "cpu_all_events_sec": cpu_all,
        "path_mtu": path_mtu,
        "ipquality": {
            "asn": prefixed("ASN"),
            "region": prefixed("Region"),
            "usage": prefixed("Usage"),
            "risk": prefixed("Risk"),
            "proxy_flags": prefixed("Proxy flags"),
            "media": prefixed("Media"),
            "dnsbl_blacklisted": dnsbl,
        },
        "ai_access": {
            "reachable": ai_reachable,
            "failed": ai_failed,
            "total": ai_total,
            "providers": ai_providers,
        },
    },
    "issues": issues,
    "conclusions": conclusions,
    "artifacts": {
        "run_dir": str(run_dir),
        "analysis": str(run_dir / "analysis.txt"),
        "ai_report": str(run_dir / "AI_REPORT.txt"),
    },
}
out.write_text(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
PY

  cp -f "$out" "$REPORT_ROOT/latest-result.json"
}

print_colored_analysis(){
  local file="$1" line status

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      " REMNANODE NEXT — MULTITEST ANALYSIS"|" ИТОГ ПО НОДЕ"|"=== TEST STATUS ==="|"=== ПРОБЛЕМЫ ===")
        printf '%s%s%s\n' "$C_CYAN" "$line" "$C_RESET"
        ;;
      "======================================================================"|"================================================================="|"==================== АНАЛИТИКА ПОСЛЕ ТЕСТОВ ====================")
        printf '%s%s%s\n' "$C_CYAN" "$line" "$C_RESET"
        ;;
      "Result:"*)
        printf '%s%s%s\n' "$C_CYAN" "$line" "$C_RESET"
        ;;
      *" PASS "*|PASS=*|*"PASS="*)
        printf '%s%s%s\n' "$C_GREEN" "$line" "$C_RESET"
        ;;
      *" SKIP "*|SKIP=*|*"SKIP="*)
        printf '%s%s%s\n' "$C_YELLOW" "$line" "$C_RESET"
        ;;
      *" FAIL "*|FAIL=*|*"FAIL="*|*"rc="*)
        if [[ "$line" == *"FAIL=0"* && "$line" != *" FAIL "* ]]; then
          printf '%s%s%s\n' "$C_GREEN" "$line" "$C_RESET"
        else
          printf '%s%s%s\n' "$C_RED" "$line" "$C_RESET"
        fi
        ;;
      "Сеть:"*|"CPU single:"*|"CPU all-thread:"*|"MTU:"*|"DNSBL blacklist:"*|"Рабочий бюджет:"*|"XHTTP ориентир:"*|"IP reputation:"*)
        printf '%s%s%s\n' "$C_GREEN" "$line" "$C_RESET"
        ;;
      "AI APIs:"*)
        if [[ "$line" == *"failed=0"* ]]; then
          printf '%s%s%s\n' "$C_GREEN" "$line" "$C_RESET"
        elif [[ "$line" == *"нет данных"* ]]; then
          printf '%s%s%s\n' "$C_YELLOW" "$line" "$C_RESET"
        else
          printf '%s%s%s\n' "$C_RED" "$line" "$C_RESET"
        fi
        ;;
      "  Нет.")
        printf '%s%s%s\n' "$C_GREEN" "$line" "$C_RESET"
        ;;
      "  #"*)
        printf '%s%s%s\n' "$C_RED" "$line" "$C_RESET"
        ;;
      Host:*|UTC:*|Run:*)
        printf '%s%s%s\n' "$C_GRAY" "$line" "$C_RESET"
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done < "$file"
}

show_latest_analysis(){
  ensure_report_root
  local dir
  dir="$(latest_report_dir)" || {
    fail 'Нет сохранённых прогонов. Сначала запусти multitest all.'
    return 1
  }
  generate_report "$dir"
  print_colored_analysis "$dir/analysis.txt"
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
  printf 'JSON:          %s/result.json\n' "$dir"
  printf 'Raw logs:      %s/*.log\n' "$dir"
}

run_all(){
  local mode="${1:-human}"
  local quiet=0
  [[ "$mode" == "machine" ]] && quiet=1

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
    "AI Access — OpenAI / Claude / Gemini / Mistral / Grok / Perplexity"
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
    "ai-access"
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
    printf 'tester=remnanode-next-server-multitest\n'
  } >"$run_dir/meta.txt"

  if (( ! quiet )); then
    say 'Автоматический режим: все тесты идут подряд без подтверждений.'
    printf '%sCtrl+C во время теста — пропустить только текущий и перейти дальше.%s\n' "$C_GRAY" "$C_RESET"
    printf 'Отчёт: %s\n' "$run_dir"
  fi

  for ((i=0; i<total; i++)); do
    num=$((i+1))
    logfile="$(printf '%s/%02d-%s.log' "$run_dir" "$num" "${slugs[$i]}")"
    if (( ! quiet )); then
      echo
      printf '%s============ [%s/%s] %s ============ %s\n' \
        "$C_CYAN" "$num" "$total" "${names[$i]}" "$C_RESET"
    fi

    started="$(date +%s)"
    set +e
    if (( quiet )); then
      run_interruptible "$num" >"$logfile" 2>&1
      rc=$?
    else
      run_interruptible "$num" 2>&1 | tee "$logfile"
      rc=${PIPESTATUS[0]}
    fi
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
        if (( ! quiet )); then
          warn "Тест $num завершился с rc=$rc"
        fi
        ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$num" "${names[$i]}" "$status" "$duration" "$rc" >>"$summary"
  done

  printf '%s\n' "$run_dir" >"$REPORT_ROOT/latest.path"
  generate_report "$run_dir"
  generate_json_report "$run_dir" "$mode" || return 1

  if (( quiet )); then
    cat "$run_dir/result.json"
    return 0
  fi

  echo
  printf '%sИтог:%s PASS=%s FAIL=%s SKIP=%s TOTAL=%s\n' \
    "$C_GREEN" "$C_RESET" "$passed" "$failed" "$skipped" "$total"
  echo
  echo '==================== АНАЛИТИКА ПОСЛЕ ТЕСТОВ ===================='
  print_colored_analysis "$run_dir/analysis.txt"
  echo '================================================================='
  echo
  printf 'Analysis:  %s/analysis.txt\n' "$run_dir"
  printf 'AI report: %s/AI_REPORT.txt\n' "$run_dir"
  printf 'JSON:      %s/result.json\n' "$run_dir"
  printf 'Повторно:  sudo remnanode-next multitest analyze\n'
  (( failed == 0 ))
}

menu(){
  local choice rc
  while true; do
    echo
    printf '%s============================================================%s\n' "$C_CYAN" "$C_RESET"
    say 'REMNANODE NEXT — SERVER MULTITEST'
    printf '%s============================================================%s\n' "$C_CYAN" "$C_RESET"
    print_list
    say ' 0) Назад'
    echo
    printf 'Выбор: '
    read -r choice < "$TTY" || choice=0
    case "$choice" in
      1|2|3|4|5|6|7|8|9|10|11|12|13)
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
  server-multitest.sh machine
  server-multitest.sh analyze
  server-multitest.sh report
  server-multitest.sh 1..13
EOF
}

main(){
  case "${1:-menu}" in
    list) print_list ;;
    -h|--help|help) usage ;;
    menu|'') need_root; menu ;;
    all|99) need_root; run_all ;;
    machine)
      need_root
      REPORT_ROOT="${MULTITEST_MACHINE_REPORT_DIR:-/tmp/remnanode-next-multitest}" \
        MULTITEST_NO_INSTALL=1 run_all machine
      ;;
    analyze) need_root; show_latest_analysis ;;
    report) need_root; show_latest_report ;;
    1|2|3|4|5|6|7|8|9|10|11|12|13) need_root; run_interruptible "$1" ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
