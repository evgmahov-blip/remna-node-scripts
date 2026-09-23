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

  local script json rc=0
  script="$(mktemp "/tmp/remna-ipquality.XXXXXX.sh")"
  json="$(mktemp "/tmp/remna-ipquality.XXXXXX.json")"

  printf '%s================ IPQuality ================%s\n' "$C_CYAN" "$C_RESET"
  if ! download_external_script "IPQuality" "$IPQUALITY_URL" "$script" "$IPQUALITY_BLOB_SHA"; then
    rm -f "$script" "$json"
    return 1
  fi

  set +e
  bash "$script" -l ru -y -p -j >"$json" 2>/dev/null
  rc=$?
  set -e

  if ! jq -e . "$json" >/dev/null 2>&1; then
    fail "IPQuality не вернул валидный JSON (rc=$rc)."
    rm -f "$script" "$json"
    return 1
  fi

  jq -r '
    def count_true(o): [o | to_entries[]? | select(.value == true)] | length;
    def count_known(o): [o | to_entries[]? | select(.value == true or .value == false)] | length;
    def values(o): [o | to_entries[]? | select(.value != null and .value != "null") | (.key + "=" + (.value|tostring))] | join(" ");
    "ASN: " + (.Info.ASN // "?") + " / " + (.Info.Organization // "?"),
    "Geo: " + (.Info.Region.Code // "?") + " " + (.Info.Region.Name // "") +
      " / registered=" + (.Info.RegisteredRegion.Code // "?") + " / " + (.Info.Type // "?"),
    "Geo consensus: " + values(.Factor.CountryCode),
    "Usage consensus: " + values(.Type.Usage),
    "Risk scores: " + values(.Score),
    "Risk factors: proxy=" + ((count_true(.Factor.Proxy))|tostring) + "/" + ((count_known(.Factor.Proxy))|tostring) +
      " vpn=" + ((count_true(.Factor.VPN))|tostring) + "/" + ((count_known(.Factor.VPN))|tostring) +
      " tor=" + ((count_true(.Factor.Tor))|tostring) + "/" + ((count_known(.Factor.Tor))|tostring) +
      " abuser=" + ((count_true(.Factor.Abuser))|tostring) + "/" + ((count_known(.Factor.Abuser))|tostring) +
      " robot=" + ((count_true(.Factor.Robot))|tostring) + "/" + ((count_known(.Factor.Robot))|tostring) +
      " datacenter=" + ((count_true(.Factor.Server))|tostring) + "/" + ((count_known(.Factor.Server))|tostring),
    "Media: " + ([.Media | to_entries[] | (.key + "=" + (.value.Status // "?") + "/" + (.value.Region // "-"))] | join(" ")),
    "Mail: port25=" + ((.Mail.Port25 // "?")|tostring),
    "DNSBL: total=" + ((.Mail.DNSBlacklist.Total // "?")|tostring) +
      " clean=" + ((.Mail.DNSBlacklist.Clean // "?")|tostring) +
      " marked=" + ((.Mail.DNSBlacklist.Marked // "?")|tostring) +
      " blacklisted=" + ((.Mail.DNSBlacklist.Blacklisted // "?")|tostring)
  ' "$json"

  local blacklisted marked proxy_hits vpn_hits tor_hits abuser_hits geo_regions
  blacklisted="$(jq -r '.Mail.DNSBlacklist.Blacklisted // -1' "$json")"
  marked="$(jq -r '.Mail.DNSBlacklist.Marked // -1' "$json")"
  proxy_hits="$(jq '[.Factor.Proxy | to_entries[]? | select(.value == true)] | length' "$json")"
  vpn_hits="$(jq '[.Factor.VPN | to_entries[]? | select(.value == true)] | length' "$json")"
  tor_hits="$(jq '[.Factor.Tor | to_entries[]? | select(.value == true)] | length' "$json")"
  abuser_hits="$(jq '[.Factor.Abuser | to_entries[]? | select(.value == true)] | length' "$json")"
  geo_regions="$(jq '[.Factor.CountryCode | to_entries[]? | select(.value != null and .value != "null") | .value] | unique | length' "$json")"

  if [[ "$blacklisted" =~ ^[0-9]+$ ]] && (( blacklisted >= 3 )); then
    echo "IP VERDICT: BAD — DNSBL blacklist=$blacklisted; адрес лучше не считать чистым для новой ноды."
  elif (( abuser_hits >= 3 || tor_hits >= 2 || proxy_hits >= 4 )); then
    echo 'IP VERDICT: BAD — несколько независимых risk-факторов считают адрес проблемным.'
  elif { [[ "$blacklisted" =~ ^[0-9]+$ ]] && (( blacklisted > 0 )); } ||
       { [[ "$marked" =~ ^[0-9]+$ ]] && (( marked >= 50 )); } ||
       (( abuser_hits > 0 || tor_hits > 0 || proxy_hits >= 2 || vpn_hits >= 3 || geo_regions > 1 )); then
    echo 'IP VERDICT: REVIEW — есть сигналы риска/расхождения; смотри Risk/Geo/DNSBL выше.'
  else
    echo 'IP VERDICT: CLEAN — критичных сигналов по доступным источникам не найдено.'
  fi
  printf 'IP evidence: proxy=%s vpn=%s tor=%s abuser=%s geo_regions=%s\n' "$proxy_hits" "$vpn_hits" "$tor_hits" "$abuser_hits" "$geo_regions"

  rm -f "$script" "$json"
  return 0
}
test_node_health(){
  need_cmd curl curl ca-certificates
  local app="/opt/remnanode" domain="" transport="" critical=0 warnings=0
  local cert="" end="" days="" disk="" mem_avail="" load="" ip4="" ip6=""

  domain="$(cat "$app/.node_domain" 2>/dev/null || true)"
  transport="$(cat "$app/.transport" 2>/dev/null || true)"

  echo '================ NODE HEALTH ================'
  printf 'Host: %s\n' "$(hostname -f 2>/dev/null || hostname)"
  printf 'Transport: %s\n' "$transport"

  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -qx remnanode; then
    echo 'Core container: OK'
  else
    echo 'Core container: FAIL'
    critical=$((critical+1))
  fi

  if ss -lnt 2>/dev/null | grep -Eq '(:|\])443[[:space:]]'; then
    echo 'TCP/443: LISTEN'
  else
    echo 'TCP/443: FAIL — listener отсутствует'
    critical=$((critical+1))
  fi

  if [[ "$transport" == *hysteria* || "$transport" == "combined" ]]; then
    if ss -lnu 2>/dev/null | grep -Eq '(:|\])443[[:space:]]'; then
      echo 'UDP/443: LISTEN'
    else
      echo 'UDP/443: FAIL — Hysteria2 выбран, listener отсутствует'
      critical=$((critical+1))
    fi
  else
    echo 'UDP/443: N/A'
  fi

  if [[ -n "$domain" ]]; then
    printf 'Domain: %s\n' "$domain"
    if getent ahostsv4 "$domain" >/dev/null 2>&1; then
      echo 'DNS A: OK'
    else
      echo 'DNS A: WARN — resolve failed'
      warnings=$((warnings+1))
    fi
  else
    echo 'Domain: WARN — not configured'
    warnings=$((warnings+1))
  fi

  for cert in "$app/certs/fullchain.pem" "/etc/xray/certs/fullchain.pem"; do
    [[ -s "$cert" ]] && break
  done
  if [[ -s "$cert" ]] && command -v openssl >/dev/null 2>&1; then
    end="$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2- || true)"
    if [[ -n "$end" ]]; then
      days=$(( ($(date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s)) / 86400 ))
      printf 'TLS expiry: %s (%s days)\n' "$end" "$days"
      if (( days < 0 )); then
        echo 'TLS: FAIL — expired'
        critical=$((critical+1))
      elif (( days < 14 )); then
        echo 'TLS: WARN — less than 14 days'
        warnings=$((warnings+1))
      else
        echo 'TLS: OK'
      fi
      if [[ -n "$domain" ]]; then
        local san wildcard
        san="$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null || true)"
        wildcard="*.${domain#*.}"
        if grep -Fq "DNS:$domain" <<<"$san" || { [[ "$domain" == *.* ]] && grep -Fq "DNS:$wildcard" <<<"$san"; }; then
          echo 'TLS SAN: OK'
        else
          echo 'TLS SAN: WARN — node domain not covered'
          warnings=$((warnings+1))
        fi
      fi
    fi
  else
    echo 'TLS: WARN — local certificate file not found'
    warnings=$((warnings+1))
  fi

  disk="$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
  mem_avail="$(awk '/MemAvailable:/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || true)"
  load="$(awk '{print $1}' /proc/loadavg 2>/dev/null || true)"
  printf 'Root disk used: %s%%\n' "$disk"
  printf 'Mem available: %s MB\n' "$mem_avail"
  printf 'Load1: %s\n' "$load"
  if [[ "$disk" =~ ^[0-9]+$ ]] && (( disk >= 90 )); then
    echo 'Disk: WARN — >=90% used'
    warnings=$((warnings+1))
  fi

  ip4="$(curl -4fsSL --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  ip6="$(curl -6fsSL --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 10 https://api64.ipify.org 2>/dev/null || true)"
  printf 'Public IPv4: %s\n' "$ip4"
  printf 'Public IPv6: %s\n' "$ip6"

  printf 'Health summary: critical=%s warnings=%s\n' "$critical" "$warnings"
  (( critical == 0 ))
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
    13) test_node_health ;;
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
13) Node Health — core / 443 / DNS / TLS / disk / memory / IPv4/IPv6
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
    grep -aE '^(ASN|Geo|Geo consensus|Usage consensus|Risk scores|Risk factors|Media|Mail|DNSBL|IP VERDICT|IP evidence):' "$dir/07-ipquality.log" | tail -30 || true
  fi

  if [[ -f "$dir/13-node-health.log" ]]; then
    echo
    echo '[Node health]'
    grep -aE '^(Core container|TCP/443|UDP/443|DNS A|TLS|Root disk|Mem available|Load1|Public IPv|Health summary):' "$dir/13-node-health.log" | tail -30 || true
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
}

print_node_scorecard(){
  local dir="$1"
  local summary
  local speed="" cpu_single="" cpu_all="" mtu="" blacklisted="" marked="" ip_verdict="" risk_factors="" geo="" health_summary=""
  local fail_count="" safe_mbps="" at3="" at5="" disk_status="" cpu_status="" route_status="" dpi_status="" geoblock_status=""
  local iperf_avg_down="" iperf_avg_up="" iperf_best_down="" iperf_best_up="" iperf_min_ping="" network_consensus=""
  local network_status="" ip_status="" media_status="" health_status="" overall_status="ОТЛИЧНО"
  local dpi_bad=0 dpi_ok=0 geoblock_bad=0 media_block=0 health_critical="" health_warnings=""
  local t5="" t8="" t9="" t10="" t11="" t12="" t13=""

  summary="$dir/summary.tsv"

  test_status(){
    awk -F '\t' -v n="$1" 'NR>1 && $1==n{print $3; exit}' "$summary" 2>/dev/null || true
  }

  worse_overall(){
    case "$1" in
      "ПЛОХО") overall_status="ПЛОХО" ;;
      "ВНИМАНИЕ") [[ "$overall_status" == "ПЛОХО" ]] || overall_status="ВНИМАНИЕ" ;;
      "НОРМАЛЬНО") [[ "$overall_status" != "ОТЛИЧНО" ]] || overall_status="НОРМАЛЬНО" ;;
    esac
    return 0
  }

  [[ -f "$dir/09-network-bench.log" ]] &&
    speed="$(awk '/Average:[[:space:]]+[0-9.]+ Mbit\/s/{print $2; exit}' "$dir/09-network-bench.log" 2>/dev/null || true)"

  if [[ -f "$dir/04-iperf-ru.log" ]]; then
    local iperf_mbps iperf_pings
    iperf_mbps="$(grep -aE '^[A-Za-z].*[0-9.]+ Mbps[[:space:]]+[0-9.]+ Mbps[[:space:]]+[0-9]+ ms' "$dir/04-iperf-ru.log" |
      grep -oE '[0-9.]+ Mbps' | awk '{print $1}' || true)"
    if [[ -n "$iperf_mbps" ]]; then
      iperf_avg_down="$(awk 'NR%2==1{s+=$1;n++} END{if(n) printf "%.1f",s/n}' <<<"$iperf_mbps")"
      iperf_avg_up="$(awk 'NR%2==0{s+=$1;n++} END{if(n) printf "%.1f",s/n}' <<<"$iperf_mbps")"
      iperf_best_down="$(awk 'NR%2==1 && $1>m{m=$1} END{if(m) printf "%.1f",m}' <<<"$iperf_mbps")"
      iperf_best_up="$(awk 'NR%2==0 && $1>m{m=$1} END{if(m) printf "%.1f",m}' <<<"$iperf_mbps")"
    fi
    iperf_pings="$(grep -aE '^[A-Za-z].*[0-9]+ ms' "$dir/04-iperf-ru.log" | grep -oE '[0-9]+ ms' | awk '{print $1}' || true)"
    [[ -n "$iperf_pings" ]] && iperf_min_ping="$(awk 'NR==1||$1<m{m=$1} END{if(NR) print m}' <<<"$iperf_pings")"
  fi

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

  [[ -f "$dir/11-nexttrace-mtu.log" ]] &&
    mtu="$(awk '/Path MTU:[[:space:]]*[0-9]+/{print $3; exit}' "$dir/11-nexttrace-mtu.log" 2>/dev/null || true)"

  if [[ -f "$dir/07-ipquality.log" ]]; then
    blacklisted="$(sed -nE 's/^DNSBL:.*blacklisted=([0-9]+).*/\1/p' "$dir/07-ipquality.log" | head -1)"
    marked="$(sed -nE 's/^DNSBL:.*marked=([0-9]+).*/\1/p' "$dir/07-ipquality.log" | head -1)"
    ip_verdict="$(sed -n 's/^IP VERDICT: //p' "$dir/07-ipquality.log" | head -1)"
    risk_factors="$(sed -n 's/^Risk factors: //p' "$dir/07-ipquality.log" | head -1)"
    geo="$(sed -n 's/^Geo: //p' "$dir/07-ipquality.log" | head -1)"
    media_block="$(grep -a '^Media:' "$dir/07-ipquality.log" 2>/dev/null | grep -oE '=(Block|No|Failed|Unavailable)(/[^ ]*)?' | wc -l | tr -d ' ' || true)"
  fi

  if [[ -f "$dir/13-node-health.log" ]]; then
    health_summary="$(sed -n 's/^Health summary: //p' "$dir/13-node-health.log" | head -1)"
    health_critical="$(sed -nE 's/^Health summary: critical=([0-9]+).*/\1/p' "$dir/13-node-health.log" | head -1)"
    health_warnings="$(sed -nE 's/^Health summary:.*warnings=([0-9]+).*/\1/p' "$dir/13-node-health.log" | head -1)"
  fi

  if [[ -f "$dir/03-censor-dpi.log" ]]; then
    dpi_bad="$(sed -E 's/\x1B\[[0-9;]*[mK]//g' "$dir/03-censor-dpi.log" |
      grep -Ec '(^|[[:space:]])(Blocked|Denied|Spoofed)([[:space:]]|$)' || true)"
    dpi_ok="$(sed -E 's/\x1B\[[0-9;]*[mK]//g' "$dir/03-censor-dpi.log" |
      grep -Ec '(^|[[:space:]])(Available|Clean)([[:space:]]|$)' || true)"
  fi

  if [[ -f "$dir/02-censor-geoblock.log" ]]; then
    geoblock_bad="$(sed -E 's/\x1B\[[0-9;]*[mK]//g' "$dir/02-censor-geoblock.log" |
      grep -Ec '(^|[[:space:]])(Blocked|Denied|Spoofed)([[:space:]]|$)' || true)"
  fi

  [[ -f "$summary" ]] &&
    fail_count="$(awk -F '\t' 'NR>1 && $3=="FAIL"{n++} END{print n+0}' "$summary")"

  t5="$(test_status 5)"
  t8="$(test_status 8)"
  t9="$(test_status 9)"
  t10="$(test_status 10)"
  t11="$(test_status 11)"
  t12="$(test_status 12)"
  t13="$(test_status 13)"

  case "$ip_verdict" in
    CLEAN*) ip_status="ОТЛИЧНО" ;;
    REVIEW*) ip_status="ВНИМАНИЕ" ;;
    BAD*) ip_status="ПЛОХО" ;;
    *) ip_status="ВНИМАНИЕ" ;;
  esac
  worse_overall "$ip_status"

  if [[ "$t9" == "FAIL" ]]; then
    network_status="ПЛОХО"
  elif [[ "$speed" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    if awk -v s="$speed" 'BEGIN{exit !(s>=500)}'; then
      network_status="ОТЛИЧНО"
    elif awk -v s="$speed" 'BEGIN{exit !(s>=150)}'; then
      network_status="НОРМАЛЬНО"
    elif awk -v s="$speed" 'BEGIN{exit !(s>=50)}'; then
      network_status="ВНИМАНИЕ"
    else
      network_status="ПЛОХО"
    fi
  else
    network_status="ВНИМАНИЕ"
  fi
  worse_overall "$network_status"

  if [[ "$t8" == "FAIL" ]]; then
    cpu_status="ПЛОХО"
  elif [[ -n "$cpu_single" && -n "$cpu_all" ]]; then
    cpu_status="НОРМАЛЬНО"
  else
    cpu_status="ВНИМАНИЕ"
  fi
  worse_overall "$cpu_status"

  if [[ "$t5" == "FAIL" ]]; then
    disk_status="ПЛОХО"
  elif [[ "$t5" == "PASS" ]]; then
    disk_status="НОРМАЛЬНО"
  else
    disk_status="ВНИМАНИЕ"
  fi
  worse_overall "$disk_status"

  if [[ "$t10" == "PASS" && "$t11" == "PASS" && "$t12" == "PASS" ]]; then
    if [[ "$mtu" == "1500" ]]; then
      route_status="ОТЛИЧНО"
    elif [[ "$mtu" =~ ^[0-9]+$ ]] && (( mtu >= 1400 )); then
      route_status="НОРМАЛЬНО"
    else
      route_status="ВНИМАНИЕ"
    fi
  elif [[ "$t10" == "FAIL" && "$t12" == "FAIL" ]]; then
    route_status="ПЛОХО"
  else
    route_status="ВНИМАНИЕ"
  fi
  worse_overall "$route_status"

  if [[ "$dpi_bad" =~ ^[0-9]+$ ]] && (( dpi_bad >= 3 )); then
    dpi_status="ПЛОХО"
  elif [[ "$dpi_bad" =~ ^[0-9]+$ ]] && (( dpi_bad > 0 )); then
    dpi_status="ВНИМАНИЕ"
  elif [[ "$dpi_ok" =~ ^[0-9]+$ ]] && (( dpi_ok > 0 )); then
    dpi_status="ОТЛИЧНО"
  else
    dpi_status="ВНИМАНИЕ"
  fi
  worse_overall "$dpi_status"

  if [[ "$media_block" =~ ^[0-9]+$ ]] && (( media_block == 0 )) &&
     [[ "$geoblock_bad" =~ ^[0-9]+$ ]] && (( geoblock_bad == 0 )); then
    media_status="ОТЛИЧНО"
  elif [[ "$media_block" =~ ^[0-9]+$ ]] && (( media_block >= 3 )); then
    media_status="ПЛОХО"
  else
    media_status="ВНИМАНИЕ"
  fi
  worse_overall "$media_status"

  if [[ "$t13" == "FAIL" ]] || { [[ "$health_critical" =~ ^[0-9]+$ ]] && (( health_critical > 0 )); }; then
    health_status="ПЛОХО"
  elif [[ "$health_critical" == "0" && "$health_warnings" == "0" ]]; then
    health_status="ОТЛИЧНО"
  elif [[ "$health_critical" == "0" && "$health_warnings" =~ ^[0-9]+$ ]]; then
    health_status="ВНИМАНИЕ"
  else
    health_status="ВНИМАНИЕ"
  fi
  worse_overall "$health_status"

  echo '======================================================================'
  echo ' ИТОГ ПО НОДЕ — ОПЕРАТОРСКАЯ ОЦЕНКА'
  echo '======================================================================'
  printf ' ОБЩИЙ ИТОГ       [%s]\n' "$overall_status"
  printf ' Тесты             FAIL=%s из 13\n' "${fail_count:-?}"
  echo '----------------------------------------------------------------------'
  printf ' IP / REPUTATION   [%-9s] %s\n' "$ip_status" "${ip_verdict:-нет verdict}"
  printf '                    Geo: %s\n' "${geo:-нет данных}"
  printf '                    DNSBL: blacklisted=%s marked=%s\n' "${blacklisted:-?}" "${marked:-?}"
  printf '                    Risk: %s\n' "${risk_factors:-нет данных}"
  echo '----------------------------------------------------------------------'
  if [[ "$speed" =~ ^[0-9]+([.][0-9]+)?$ && "$iperf_avg_down" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    local lo hi pct
    if awk -v a="$speed" -v b="$iperf_avg_down" 'BEGIN{exit !(a<b)}'; then
      lo="$speed"; hi="$iperf_avg_down"
    else
      lo="$iperf_avg_down"; hi="$speed"
    fi
    pct="$(awk -v a="$hi" -v b="$lo" 'BEGIN{if(a>0) printf "%.0f", ((a-b)/a)*100; else print 0}')"
    if (( pct <= 15 )); then
      network_consensus="результаты хорошо согласуются: download ~${lo}-${hi} Mbit/s"
    elif (( pct <= 30 )); then
      network_consensus="результаты в разумном диапазоне: download ~${lo}-${hi} Mbit/s"
    else
      network_consensus="заметный разброс между тестами: download ~${lo}-${hi} Mbit/s"
    fi
    if [[ "$iperf_avg_up" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      network_consensus="${network_consensus}; upload avg ~${iperf_avg_up} Mbit/s"
    fi
  elif [[ "$speed" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    network_consensus="есть только Cloudflare measurement: ~${speed} Mbit/s download"
  elif [[ "$iperf_avg_down" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    network_consensus="есть только iPerf3 RU: avg download ~${iperf_avg_down} Mbit/s"
  else
    network_consensus="недостаточно данных для сетевого консенсуса"
  fi

  printf ' СЕТЬ              [%-9s] %s\n' "$network_status" "$network_consensus"
  printf '                    Cloudflare HTTPS 100MB: %s\n' "$([[ -n "$speed" ]] && printf '%s Mbit/s download' "$speed" || printf 'нет данных')"
  if [[ -n "$iperf_avg_down" || -n "$iperf_avg_up" ]]; then
    printf '                    iPerf3 RU (5 точек): avg ↓%s / ↑%s Mbit/s; best ↓%s / ↑%s; min ping %sms\n' \
      "${iperf_avg_down:-?}" "${iperf_avg_up:-?}" "${iperf_best_down:-?}" "${iperf_best_up:-?}" "${iperf_min_ping:-?}"
  fi
  if [[ "$speed" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    safe_mbps="$(awk -v s="$speed" 'BEGIN{printf "%.1f", s*0.70}')"
    at3="$(awk -v s="$safe_mbps" 'BEGIN{print int(s/3)}')"
    at5="$(awk -v s="$safe_mbps" 'BEGIN{print int(s/5)}')"
    printf '                    расчётный бюджет по Cloudflare (70%%): ~%s Mbit/s\n' "$safe_mbps"
    printf '                    ориентир XHTTP: ~%s активных @3 Mbit/s / ~%s @5 Mbit/s\n' "$at3" "$at5"
  fi
  echo '----------------------------------------------------------------------'
  printf ' CPU               [%-9s] single=%s all=%s events/s\n' "$cpu_status" "${cpu_single:-?}" "${cpu_all:-?}"
  printf ' ДИСК              [%-9s] fio test=%s\n' "$disk_status" "${t5:-нет данных}"
  echo '----------------------------------------------------------------------'
  printf ' МАРШРУТЫ / MTU    [%-9s] MTR=%s PMTU=%s Globalping=%s MTU=%s\n' "$route_status" "${t10:-?}" "${t11:-?}" "${t12:-?}" "${mtu:-?}"
  printf ' DPI               [%-9s] bad-signals=%s clean-signals=%s\n' "$dpi_status" "$dpi_bad" "$dpi_ok"
  printf ' GEO / MEDIA       [%-9s] geoblock-signals=%s media-blocks=%s\n' "$media_status" "$geoblock_bad" "$media_block"
  echo '----------------------------------------------------------------------'
  printf ' TLS / RUNTIME     [%-9s] %s\n' "$health_status" "${health_summary:-нет данных}"
  echo '======================================================================'
  echo ' ЛЕГЕНДА: ОТЛИЧНО = чисто/сильный результат; НОРМАЛЬНО = рабочий результат;'
  echo '         ВНИМАНИЕ = есть отклонения или неполные данные; ПЛОХО = критичный сигнал.'
  echo ' CPU/диск не получают искусственный рейтинг производительности: показываются фактические метрики.'
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

print_colored_analysis(){
  local file="$1" line status

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      " REMNANODE NEXT — MULTITEST ANALYSIS"|" ИТОГ ПО НОДЕ — ОПЕРАТОРСКАЯ ОЦЕНКА"|"=== TEST STATUS ==="|"=== ПРОБЛЕМЫ ===")
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
      *" FAIL "*|FAIL=*|*"FAIL="*|*"rc="*)
        if [[ "$line" == *"FAIL=0"* && "$line" != *" FAIL "* ]]; then
          printf '%s%s%s\n' "$C_GREEN" "$line" "$C_RESET"
        else
          printf '%s%s%s\n' "$C_RED" "$line" "$C_RESET"
        fi
        ;;
      *" SKIP "*|SKIP=*|*"SKIP="*)
        printf '%s%s%s\n' "$C_YELLOW" "$line" "$C_RESET"
        ;;
      *"[ОТЛИЧНО]"*)
        printf '%s%s%s\n' "$C_GREEN" "$line" "$C_RESET"
        ;;
      *"[НОРМАЛЬНО]"*)
        printf '%s%s%s\n' "$C_GREEN" "$line" "$C_RESET"
        ;;
      *"[ВНИМАНИЕ]"*)
        printf '%s%s%s\n' "$C_YELLOW" "$line" "$C_RESET"
        ;;
      *"[ПЛОХО]"*)
        printf '%s%s%s\n' "$C_RED" "$line" "$C_RESET"
        ;;
      "Сеть:"*|"CPU single:"*|"CPU all-thread:"*|"MTU:"*|"Geo/IP location:"*|"DNSBL:"*|"IP verdict:"*|"Risk factors:"*|"Node health:"*|"Рабочий бюджет:"*|"XHTTP ориентир:"*|"IP reputation:"*)
        printf '%s%s%s\n' "$C_GREEN" "$line" "$C_RESET"
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
    "Node Health"
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
    "node-health"
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
  echo
  echo '==================== АНАЛИТИКА ПОСЛЕ ТЕСТОВ ===================='
  print_colored_analysis "$run_dir/analysis.txt"
  echo '================================================================='
  echo
  printf 'Analysis:  %s/analysis.txt\n' "$run_dir"
  printf 'AI report: %s/AI_REPORT.txt\n' "$run_dir"
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
    analyze) need_root; show_latest_analysis ;;
    report) need_root; show_latest_report ;;
    1|2|3|4|5|6|7|8|9|10|11|12|13) need_root; run_interruptible "$1" ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
