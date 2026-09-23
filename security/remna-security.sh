#!/usr/bin/env bash
# RemnaNode Security CLI. Human menu plus stable JSON for status/preflight/update/selftest.
set -Eeuo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PY="$HERE/remna_sec.py"
BASE=${REMNA_SECURITY_BASE:-/opt/remna-protection}
CONF=$BASE/settings.conf
DATA=$BASE/data
SIM=${REMNA_SECURITY_SIM:-0}
FORBID=${REMNA_SECURITY_FORBID_LIVE:-0}
if [ "$SIM" = 1 ]; then
  LOGDIR=$BASE/log
else
  LOGDIR=/var/log/remna-protection
fi
ACTION_LOG=$LOGDIR/actions.log
UPDATE_LOG=$LOGDIR/update.log
JSON=0
REMNA_MUTATION=${REMNA_MUTATION:-0}
REMNA_IN_ROLLBACK=${REMNA_IN_ROLLBACK:-0}
MENU_BACK_RC=20

TSPU_COMMIT=a465e13f4cb43c1692eb650430eb857900558c5d
TSPU_BLOB_SHA=e7509cb2a8576fc659f23731d5974353f46860dc
TSPU_URL="https://raw.githubusercontent.com/tread-lightly/CyberOK_Skipa_ips/${TSPU_COMMIT}/lists/skipa_cidr.txt"
GOV_COMMIT=0e999cd730c4d6ca3d58053407a22f63f2d464e6
GOV_BLOB_SHA=2b179cc00d7e805e1c49e975e18229ec811c82af
GOV_URL="https://raw.githubusercontent.com/C24Be/AS_Network_List/${GOV_COMMIT}/blacklists_iptables/blacklist-v4.ipset"
GEOIP_COMMIT=6e3f7978b0391935e306060b11beba774fc7f624
GEOIP_BASE="https://raw.githubusercontent.com/ipverse/country-ip-blocks/${GEOIP_COMMIT}/country"

say() { printf '%s\n' "$*"; }
ok() { printf '✓ %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die() {
  if [ "$JSON" = 1 ]; then
    python3 -c 'import json,sys; print(json.dumps({"ok": False, "error": sys.argv[1]}))' "$1"
  fi
  printf '✗ %s\n' "$1" >&2
  exit 1
}
is_menu_back() { case "${1:-}" in 0|q|Q|back|BACK|Back|назад|Назад|НАЗАД) return 0 ;; *) return 1 ;; esac; }
log_action() {
  mkdir -p "$LOGDIR"
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$ACTION_LOG"
}

py() { python3 "$PY" "$@"; }

lock() {
  mkdir -p "$BASE"
  exec 9>>"$BASE/remna-security.lock"
  flock -w 30 9
}

ensure_key() {
  local key=$1 value=$2
  if ! grep -q "^${key}=" "$CONF"; then
    printf '%s=%s\n' "$key" "$value" >> "$CONF"
  fi
}

write_defaults() {
  mkdir -p "$BASE" "$DATA" "$LOGDIR"
  chmod 0700 "$BASE" "$DATA" || true
  if [ ! -f "$CONF" ]; then
    cat > "$CONF" <<'EOF'
PANEL_IP=
ENABLE_TSPU=1
ENABLE_GOV=1
ENABLE_GEOIP=0
ENABLE_SCANNERS=0
FILTER_PORTS=443
GEO_COUNTRIES=
SCANNER_URL=
BACKEND=iptables
LOG_DROPS=0
EOF
    chmod 0600 "$CONF"
  else
    ensure_key PANEL_IP ""
    ensure_key ENABLE_TSPU 1
    ensure_key ENABLE_GOV 1
    ensure_key ENABLE_GEOIP 0
    ensure_key ENABLE_SCANNERS 0
    ensure_key FILTER_PORTS 443
    ensure_key GEO_COUNTRIES ""
    ensure_key SCANNER_URL ""
    ensure_key BACKEND iptables
    ensure_key LOG_DROPS 0
    chmod 0600 "$CONF" || true
  fi
  local f
  for f in allow.txt deny.txt countries.txt tspu.txt gov.txt scanners.txt; do
    touch "$DATA/$f"
    chmod 0600 "$DATA/$f" || true
  done
}

load_conf() {
  write_defaults
  PANEL_IP=""
  ENABLE_TSPU=1
  ENABLE_GOV=1
  ENABLE_GEOIP=0
  ENABLE_SCANNERS=0
  FILTER_PORTS=443
  GEO_COUNTRIES=""
  SCANNER_URL=""
  BACKEND=iptables
  LOG_DROPS=0
  local line key
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    case "$key" in
      PANEL_IP|ENABLE_TSPU|ENABLE_GOV|ENABLE_GEOIP|ENABLE_SCANNERS|FILTER_PORTS|GEO_COUNTRIES|SCANNER_URL|BACKEND|LOG_DROPS)
        printf -v "$key" '%s' "${line#*=}"
        ;;
    esac
  done < "$CONF"
}

valid_ip() { python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$1"; }
valid_ports() {
  python3 -c 'import sys
raw=sys.argv[1]
vals=[int(x.strip()) for x in raw.split(",") if x.strip()]
ok=bool(vals) and len(vals)<=15 and all(1<=n<=65535 for n in vals)
raise SystemExit(0 if ok else 1)' "$1"
}

set_conf() {
  local key=$1 value=$2 tmp
  case "$key" in
    PANEL_IP) [ -z "$value" ] || valid_ip "$value" || die "Некорректный PANEL_IP" ;;
    ENABLE_TSPU|ENABLE_GOV|ENABLE_GEOIP|ENABLE_SCANNERS|LOG_DROPS) [[ "$value" =~ ^[01]$ ]] || die "Для $key допустимы только 0 или 1" ;;
    FILTER_PORTS) valid_ports "$value" || die "Некорректный список портов" ;;
    GEO_COUNTRIES) [[ "$value" =~ ^([A-Za-z]{2})(,[A-Za-z]{2})*$|^$ ]] || die "GEO_COUNTRIES: ожидается список ISO-кодов" ;;
    BACKEND) [[ "$value" =~ ^(iptables|nftables)$ ]] || die "BACKEND: iptables или nftables" ;;
    SCANNER_URL)
      if [ -n "$value" ]; then
        [[ "$value" =~ ^https:// ]] || die "SCANNER_URL должен быть https://"
      fi
      ;;
    *) die "Запрещён неизвестный ключ конфигурации: $key" ;;
  esac
  snapshot_before
  tmp=$(mktemp)
  awk -F= -v k="$key" -v v="$value" 'BEGIN{done=0} $1==k{print k"="v; done=1; next} {print} END{if(!done) print k"="v}' "$CONF" > "$tmp"
  mv "$tmp" "$CONF"
  chmod 0600 "$CONF"
  load_conf
}

snapshot_before() {
  if [ "$REMNA_MUTATION" = 1 ] || [ "$REMNA_IN_ROLLBACK" = 1 ]; then
    return 0
  fi
  local id dir
  id=$(date '+%Y%m%d%H%M%S').$$
  dir=$BASE/rollback/$id
  mkdir -p "$dir/data"
  if [ -f "$CONF" ]; then cp -a "$CONF" "$dir/settings.conf"; fi
  if [ -d "$DATA" ]; then cp -a "$DATA/." "$dir/data/"; fi
  printf '%s\n' "$id" > "$BASE/rollback/LATEST"
  REMNA_MUTATION=1
  find "$BASE/rollback" -mindepth 1 -maxdepth 1 -type d | sort | head -n -5 | while IFS= read -r old; do
    [ -n "$old" ] && rm -rf "$old"
  done
}

restore_latest_files() {
  local id dir
  [ -f "$BASE/rollback/LATEST" ] || die "Снимок отката отсутствует"
  id=$(tr -d '[:space:]' < "$BASE/rollback/LATEST")
  dir=$BASE/rollback/$id
  [ -f "$dir/settings.conf" ] || die "Снимок $id неполный"
  cp -a "$dir/settings.conf" "$CONF"
  rm -rf "$DATA"
  mkdir -p "$DATA"
  cp -a "$dir/data/." "$DATA/"
  load_conf
}

run_apply() {
  local rc=0
  if [ "$REMNA_IN_ROLLBACK" = 1 ]; then
    env -u REMNA_SIM_FAIL_SWAP python3 "$PY" apply --base "$BASE" || rc=$?
  else
    python3 "$PY" apply --base "$BASE" || rc=$?
  fi
  return "$rc"
}

apply_rules() {
  load_conf
  snapshot_before
  if run_apply; then
    log_action "rules applied backend=$BACKEND panel=$PANEL_IP ports=$FILTER_PORTS"
    return 0
  fi
  warn "Применение owned-ruleset не удалось; возвращаю последний снимок."
  if [ "$REMNA_IN_ROLLBACK" = 1 ]; then
    return 1
  fi
  REMNA_IN_ROLLBACK=1
  restore_latest_files
  run_apply || warn "Повторное применение снимка не удалось."
  return 1
}

fetch_url() {
  local url=$1 dst=$2
  case "$url" in
    file://*)
      [ "$SIM" = 1 ] || return 1
      cp "${url#file://}" "$dst"
      ;;
    https://*)
      if [ "$SIM" = 1 ] && [ -z "${REMNA_SECURITY_CURL_BIN:-}" ]; then
        warn "В симуляторе сеть отключена."
        return 1
      fi
      if [ -n "${REMNA_SECURITY_CURL_BIN:-}" ]; then
        "$REMNA_SECURITY_CURL_BIN" "$url" "$dst"
      else
        command curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 --retry 2 "$url" -o "$dst"
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

append_result() {
  RESULT_ITEM=$1 python3 - "$RESULTS" <<'PY'
import json, os, sys
path = sys.argv[1]
item = json.loads(os.environ["RESULT_ITEM"])
data = []
if os.path.exists(path) and os.path.getsize(path):
    data = json.loads(open(path, encoding="utf-8").read())
data.append(item)
open(path, "w", encoding="utf-8").write(json.dumps(data))
PY
}

fail_result() {
  local id=$1 reason=$2
  append_result "{\"id\":\"${id}\",\"ok\":false,\"reason\":\"${reason}\",\"accepted\":0,\"kept_lkg\":true,\"panel_collisions\":0,\"whitelist_collisions\":0}"
}

pin_matches() {
  local file=$1 expected=$2 actual
  actual=$(py blob --file "$file")
  [ "$actual" = "$expected" ]
}

update_source() {
  local id=$1 url=$2 blob=${3:-}
  local raw rc=0 out
  raw=$(mktemp)
  if ! fetch_url "$url" "$raw"; then
    fail_result "$id" download
    rm -f "$raw"
    return 1
  fi
  if python3 -c 'import pathlib,sys; data=pathlib.Path(sys.argv[1]).read_bytes()[:1024].lower(); sys.exit(0 if any(m in data for m in (b"<!doctype", b"<html", b"<head", b"<body")) else 1)' "$raw"; then
    fail_result "$id" html
    rm -f "$raw"
    return 1
  fi
  if [ ! -s "$raw" ]; then
    fail_result "$id" empty
    rm -f "$raw"
    return 1
  fi
  case "$url" in
    https://*)
      if [ -n "$blob" ] && ! pin_matches "$raw" "$blob"; then
        fail_result "$id" integrity
        rm -f "$raw"
        return 1
      fi
      ;;
  esac
  out=$(py accept-source --base "$BASE" --id "$id" --raw "$raw") || rc=$?
  append_result "$out"
  rm -f "$raw"
  return "$rc"
}

update_geo() {
  local raw=$1
  : > "$raw"
  if [ -n "${REMNA_SECURITY_SOURCE_GEO:-}" ]; then
    fetch_url "$REMNA_SECURITY_SOURCE_GEO" "$raw" || return 1
    return 0
  fi
  local code tmp failed=0
  IFS=',' read -ra codes <<< "$GEO_COUNTRIES"
  for code in "${codes[@]}"; do
    code=$(printf '%s' "$code" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    [ -n "$code" ] || continue
    tmp=$(mktemp)
    if fetch_url "${GEOIP_BASE}/${code}/ipv4-aggregated.txt" "$tmp"; then
      cat "$tmp" >> "$raw"
    else
      failed=1
    fi
    rm -f "$tmp"
  done
  [ "$failed" -eq 0 ]
}

update_blocklists() {
  load_conf
  valid_ip "$PANEL_IP" || die "PANEL_IP не задан/некорректен. Сначала: panel-set <IP>."
  snapshot_before
  RESULTS=$(mktemp)
  printf '[]' > "$RESULTS"
  local failed=0
  update_source tspu "${REMNA_SECURITY_SOURCE_TSPU:-$TSPU_URL}" "$TSPU_BLOB_SHA" || failed=1
  update_source gov "${REMNA_SECURITY_SOURCE_GOV:-$GOV_URL}" "$GOV_BLOB_SHA" || failed=1
  if [ "$ENABLE_SCANNERS" = 1 ]; then
    if [ -n "${REMNA_SECURITY_SOURCE_SCANNERS:-}" ]; then
      update_source scanners "$REMNA_SECURITY_SOURCE_SCANNERS" "" || failed=1
    elif [ -n "$SCANNER_URL" ]; then
      update_source scanners "$SCANNER_URL" "" || failed=1
    else
      fail_result scanners empty
      failed=1
    fi
  fi
  if [ "$ENABLE_GEOIP" = 1 ]; then
    local geo out rc=0
    geo=$(mktemp)
    if update_geo "$geo"; then
      out=$(py accept-source --base "$BASE" --id geoip --raw "$geo") || rc=$?
      append_result "$out"
      [ "$rc" -eq 0 ] || failed=1
    else
      fail_result geoip download
      failed=1
    fi
    rm -f "$geo"
  fi
  if ! run_apply; then
    failed=1
    append_result '{"id":"apply","ok":false,"reason":"apply","accepted":0,"kept_lkg":true,"panel_collisions":0,"whitelist_collisions":0}'
    if [ "$REMNA_IN_ROLLBACK" != 1 ]; then
      REMNA_IN_ROLLBACK=1
      restore_latest_files
      run_apply || true
    fi
  fi
  py finalize-update --base "$BASE" --results "$RESULTS" >/dev/null
  rm -f "$RESULTS"
  mkdir -p "$LOGDIR"
  printf '[%s] ok=%s\n' "$(date '+%F %T')" "$failed" >> "$UPDATE_LOG"
  if [ "$JSON" = 1 ]; then
    py emit update --base "$BASE"
  else
    if [ "$failed" -eq 0 ]; then
      ok "Источники проверены, временный набор заменён атомарно, last-known-good сохранён."
    else
      warn "Часть источников отклонена. Last-known-good сохранён для неуспешных фидов."
    fi
  fi
  return "$failed"
}

write_units() {
  local dest entry
  entry=${REMNA_SECURITY_ENTRY:-$HERE/remna-security.sh}
  if [ "$SIM" = 1 ]; then
    dest=$BASE/sim/units
  else
    dest=/etc/systemd/system
  fi
  py write-units --base "$BASE" --dest "$dest" --entrypoint "$entry"
  py write-logrotate --dest "$([ "$SIM" = 1 ] && printf '%s' "$BASE/sim/logrotate.conf" || printf '%s' /etc/logrotate.d/remna-protection)"
  if [ "$SIM" != 1 ] && [ "$FORBID" != 1 ]; then
    systemctl daemon-reload
    systemctl enable remna-protection.service >/dev/null 2>&1 || true
    systemctl enable --now remna-protection-update.timer >/dev/null 2>&1 || true
  fi
}

add_step() {
  NAME=$1 OK=$2 DETAIL=$3 python3 - "$STEPS" <<'PY'
import json, os, sys
path = sys.argv[1]
data = json.loads(open(path, encoding="utf-8").read())
data.append({"name": os.environ["NAME"], "ok": os.environ["OK"] == "1", "detail": os.environ["DETAIL"]})
open(path, "w", encoding="utf-8").write(json.dumps(data))
PY
}

node_api() {
  py emit status --base "$BASE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["node_api_2222"])'
}

self_test() {
  load_conf
  STEPS=$BASE/data/selftest-steps.json
  mkdir -p "$DATA"
  printf '[]' > "$STEPS"
  if valid_ip "$PANEL_IP"; then add_step panel 1 ok; else add_step panel 0 missing; fi
  write_units
  if [ -f "$BASE/sim/units/remna-protection.service" ] || [ -f /etc/systemd/system/remna-protection.service ]; then
    add_step units 1 written
  else
    add_step units 0 missing
  fi
  if apply_rules; then add_step apply 1 ok; else add_step apply 0 failed; fi
  if [ "$(node_api)" = protected ]; then add_step node_api 1 protected; else add_step node_api 0 "$(node_api)"; fi
  if [ "$SIM" = 1 ]; then
    py sim-drop-hook --base "$BASE"
    if [ "$(node_api)" = unprotected ]; then add_step hook_removed 1 ok; else add_step hook_removed 0 "$(node_api)"; fi
    REMNA_MUTATION=0
    if apply_rules && [ "$(node_api)" = protected ]; then
      add_step restore 1 ok
    else
      add_step restore 0 failed
    fi
    local audit
    audit=$(py audit --base "$BASE")
    AUDIT_JSON=$audit python3 - "$STEPS" <<'PY'
import json, os, sys
path = sys.argv[1]
audit = json.loads(os.environ["AUDIT_JSON"])
data = json.loads(open(path, encoding="utf-8").read())
data.append({"name": "single_jump", "ok": audit["guard_jumps"] == 1 and audit["guard6_jumps"] == 1, "detail": str(audit["guard_jumps"])})
data.append({"name": "foreign_ssh", "ok": audit["ssh_accept"], "detail": "ssh"})
data.append({"name": "unsafe_commands", "ok": audit["unsafe_commands"] == [], "detail": ",".join(audit["unsafe_commands"])})
data.append({"name": "wide_ufw_2222", "ok": not audit["wide_ufw_2222"], "detail": "ufw"})
open(path, "w", encoding="utf-8").write(json.dumps(data))
PY
  fi
  local doc
  doc=$(py emit selftest --base "$BASE" --steps "$STEPS")
  if [ "$JSON" = 1 ]; then
    printf '%s\n' "$doc"
  else
    printf '%s\n' "$doc" | python3 -c 'import json,sys
doc=json.load(sys.stdin)
print("=== RemnaNode Security self-test ===")
for step in doc["steps"]:
    mark = "ok" if step["ok"] else "FAIL"
    print("[%s] %s %s" % (mark, step["name"], step["detail"]))
print("SELFTEST:", "PASS" if doc["ok"] else "FAIL")
'
  fi
  printf '%s\n' "$doc" | python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin)["ok"] else 1)'
}

cmd_status() {
  load_conf
  if [ "$JSON" = 1 ]; then
    py emit status --base "$BASE"
    return 0
  fi
  py emit status --base "$BASE" | python3 -c 'import json,sys
d=json.load(sys.stdin)
ports=",".join(str(p) for p in d["filter_ports"])
panel=d["panel_ip"] or "НЕ ЗАДАН"
src=d["sources"]
print("=== RemnaNode Security ===")
print("Backend      : %s (%s)" % (d["backend"], d["backend_implementation"]))
print("Panel IP     : %s" % panel)
print("TCP/2222     : %s" % d["node_api_2222"])
print("Ports        : %s" % ports)
print("TSPU         : %s (%s entries, pinned, ipv4)" % (src["tspu"]["enabled"], src["tspu"]["entries"]))
print("GOV          : %s (%s entries, pinned, ipv4)" % (src["gov"]["enabled"], src["gov"]["entries"]))
print("Scanners     : %s (%s entries, fast, ipv4)" % (src["scanners"]["enabled"], src["scanners"]["entries"]))
print("GeoIP        : %s (%s entries)" % (src["geoip"]["enabled"], src["geoip"]["entries"]))
print("IPv6 lists   : dynamic=false")
print("Ruleset      : %s" % d["ruleset_health"])
print("Last update  : ok=%s error=%s" % (d["last_update"]["ok"], d["last_update"]["error"]))
print("Active src   : %s" % d["active_source_count"])
'
}

cmd_preflight() {
  local target=${1:-} doc
  load_conf
  if [ -n "$target" ]; then
    doc=$(py emit preflight --base "$BASE" --target "$target")
  else
    doc=$(py emit preflight --base "$BASE")
  fi
  if [ "$JSON" = 1 ]; then
    printf '%s\n' "$doc"
  else
    printf '%s\n' "$doc" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print("=== Preflight ===")
print("ok:", d["ok"])
print("detected:", d["detected_backend"])
print("configured:", d["configured_backend"])
print("nft:", d["nft_activation"], d["nft_refuse_reason"])
print("blockers:", ", ".join(d["blockers"]) or "-")
print("warnings:", ", ".join(d["warnings"]) or "-")
'
  fi
  printf '%s\n' "$doc" | python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin)["ok"] else 1)'
}

set_panel_ip() {
  local ip=${1:-}
  load_conf
  if [ -z "$ip" ]; then
    [ -t 0 ] || die "PANEL_IP не задан."
    printf 'IP панели Remnawave (0 = назад): '
    read -r ip || true
    is_menu_back "$ip" && return "$MENU_BACK_RC"
  fi
  valid_ip "$ip" || die "Некорректный IP панели: $ip"
  set_conf PANEL_IP "$ip"
  apply_rules
  ok "TCP/2222 разрешён только панели $ip; для остальных DROP."
}

ensure_panel_ip() {
  load_conf
  if [ -n "${PANEL_IP_ENV:-}" ]; then set_panel_ip "$PANEL_IP_ENV"; return; fi
  if [ -n "$PANEL_IP" ] && valid_ip "$PANEL_IP"; then apply_rules; return; fi
  if [ -t 0 ]; then
    set_panel_ip
  else
    warn "PANEL_IP не задан: firewall не меняю."
    return 1
  fi
}

install_all() {
  load_conf
  write_units
  ensure_panel_ip
  update_blocklists || warn "Списки не обновились; применяю сохранённые правила."
  ok "Защита установлена. Backend=$BACKEND. Производственная активация этим прогоном не выполняется."
}

manual_change() {
  local file=$1 value=$2 mode=${3:-add}
  if [ "$mode" = add ]; then
    py manual --base "$BASE" --file "$file" --value "$value"
  else
    py manual --base "$BASE" --file "$file" --value "$value" --remove
  fi
  apply_rules
}

uninstall_all() {
  snapshot_before
  if [ "$SIM" != 1 ] && [ "$FORBID" != 1 ]; then
    systemctl disable --now remna-protection-update.timer remna-protection.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/remna-protection.service /etc/systemd/system/remna-protection-update.service /etc/systemd/system/remna-protection-update.timer
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  py uninstall --base "$BASE"
  ok "Owned firewall resources удалены. Конфиг $BASE сохранён."
}

backend_switch() {
  local target=${1:-} flag=${2:-}
  [ "$flag" = "--confirm" ] || die "backend-switch <iptables|nftables> --confirm"
  case "$target" in
    iptables|nftables) ;;
    *) die "Неизвестный backend" ;;
  esac
  local pre rc=0
  pre=$(py emit preflight --base "$BASE" --target "$target")
  python3 -c 'import json,sys; raise SystemExit(0 if json.loads(sys.argv[1])["ok"] else 1)' "$pre" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$JSON" = 1 ]; then printf '%s\n' "$pre"; fi
    warn "Переключение backend отклонено preflight."
    return 1
  fi
  set_conf BACKEND "$target"
  apply_rules
}

migrate_inplace() {
  snapshot_before
  write_defaults
  mkdir -p "$DATA/lkg"
  local f
  for f in allow.txt deny.txt countries.txt tspu.txt gov.txt scanners.txt; do
    if [ -s "$DATA/$f" ] && [ ! -s "$DATA/lkg/$f" ]; then
      cp "$DATA/$f" "$DATA/lkg/$f"
      chmod 0600 "$DATA/lkg/$f"
    fi
  done
  ok "In-place миграция настроек выполнена. Firewall не переключался."
}

cmd_rollback() {
  REMNA_IN_ROLLBACK=1
  restore_latest_files
  run_apply
  ok "Откат к снимку применён."
}

rkn_enable() {
  set_conf ENABLE_TSPU 1
  set_conf ENABLE_GOV 1
  write_units
  update_blocklists || apply_rules || true
  ok "RKN-защита включена: TSPU + GOV на FILTER_PORTS (только TCP)."
}

rkn_disable() {
  set_conf ENABLE_TSPU 0
  set_conf ENABLE_GOV 0
  apply_rules
  ok "TSPU/GOV выключены. TCP/2222 и owned chain сохранены."
}

menu() {
  while true; do
    cat <<'EOF'

────────────────────────────────────────────────────────────
RemnaNode Security
────────────────────────────────────────────────────────────
 [1] Установить/обновить защиту
 [2] Задать IP панели и закрыть 2222
 [3] Обновить источники
 [4] Статус
 [5] Добавить allow IP/CIDR
 [6] Удалить allow IP/CIDR
 [7] Добавить deny IP/CIDR
 [8] Удалить deny IP/CIDR
 [9] Включить GeoIP allow-страны
 [10] Выключить GeoIP
 [11] Изменить защищаемые TCP-порты
 [12] Удалить owned firewall-защиту
 [13] Самопроверка
 [14] Preflight
 [15] Откат последнего снимка
 [0] Назад
────────────────────────────────────────────────────────────
EOF
    printf 'Выбор: '
    local c v rc
    read -r c || true
    case "$c" in
      1) install_all || rc=$?; rc=${rc:-0}; [ "$rc" -eq 0 ] || [ "$rc" -eq "$MENU_BACK_RC" ] || warn "код $rc" ;;
      2) set_panel_ip || rc=$?; rc=${rc:-0}; [ "$rc" -eq 0 ] || [ "$rc" -eq "$MENU_BACK_RC" ] || warn "код $rc" ;;
      3) update_blocklists || true ;;
      4) cmd_status || true ;;
      5) printf 'IP/CIDR allow (0 = назад): '; read -r v || true; is_menu_back "$v" && continue; manual_change allow.txt "$v" add || true ;;
      6) printf 'IP/CIDR удалить из allow (0 = назад): '; read -r v || true; is_menu_back "$v" && continue; manual_change allow.txt "$v" del || true ;;
      7) printf 'IP/CIDR deny (0 = назад): '; read -r v || true; is_menu_back "$v" && continue; manual_change deny.txt "$v" add || true ;;
      8) printf 'IP/CIDR удалить из deny (0 = назад): '; read -r v || true; is_menu_back "$v" && continue; manual_change deny.txt "$v" del || true ;;
      9) printf 'Коды стран (0 = назад): '; read -r v || true; is_menu_back "$v" && continue; set_conf GEO_COUNTRIES "$v"; set_conf ENABLE_GEOIP 1; apply_rules || true ;;
      10) set_conf ENABLE_GEOIP 0; apply_rules || true ;;
      11) printf 'TCP-порты (0 = назад): '; read -r v || true; is_menu_back "$v" && continue; set_conf FILTER_PORTS "$v"; apply_rules || true ;;
      12) printf 'Удалить owned-правила? YES: '; read -r v || true; [ "$v" = YES ] && uninstall_all || warn "Отменено." ;;
      13) self_test || true ;;
      14) cmd_preflight || true ;;
      15) cmd_rollback || true ;;
      0|'') return 0 ;;
      *) warn "Неизвестный пункт" ;;
    esac
  done
}

parse_json_flag() {
  local arg
  CMD=()
  for arg in "$@"; do
    if [ "$arg" = "--json" ]; then
      JSON=1
    else
      CMD+=("$arg")
    fi
  done
}

rkn_menu() {
  while true; do
    cat <<'EOF'

────────────────────────────────────────────────────────────
РКН защита — TSPU / GOV
────────────────────────────────────────────────────────────
 [1] Включить / установить RKN-защиту
 [2] Обновить TSPU/GOV списки сейчас
 [3] Статус RKN-защиты
 [4] Выключить TSPU/GOV фильтрацию
 [0] Назад
────────────────────────────────────────────────────────────
EOF
    printf 'Выбор: '
    local c
    read -r c || true
    case "$c" in
      1) rkn_enable || true ;;
      2) update_blocklists || true ;;
      3) cmd_status || true ;;
      4) rkn_disable || true ;;
      0|'') return 0 ;;
      *) warn "Неизвестный пункт: $c" ;;
    esac
  done
}

main() {
  parse_json_flag "$@"
  if [ "${#CMD[@]}" -eq 0 ]; then
    set --
  else
    set -- "${CMD[@]}"
  fi
  lock
  case "${1:-menu}" in
    menu|'') menu ;;
    rkn|rkn-menu) rkn_menu ;;
    rkn-enable) rkn_enable ;;
    rkn-disable) rkn_disable ;;
    rkn-status) cmd_status ;;
    install) install_all ;;
    update) update_blocklists ;;
    apply) apply_rules ;;
    status) cmd_status ;;
    preflight) shift || true; cmd_preflight "${1:-}" ;;
    selftest|self-test|repair) self_test ;;
    panel-set) shift; set_panel_ip "${1:-}" ;;
    ensure-panel) ensure_panel_ip ;;
    check-node-api)
      local api
      api=$(node_api)
      printf '%s\n' "$api"
      [ "$api" = protected ]
      ;;
    allow-add) shift; manual_change allow.txt "$1" add ;;
    deny-add) shift; manual_change deny.txt "$1" add ;;
    allow-del) shift; manual_change allow.txt "$1" del ;;
    deny-del) shift; manual_change deny.txt "$1" del ;;
    uninstall) uninstall_all ;;
    rollback) cmd_rollback ;;
    backend-switch) shift; backend_switch "${1:-}" "${2:-}" ;;
    migrate-inplace) migrate_inplace ;;
    config-set) shift; set_conf "${1:-}" "${2:-}"; apply_rules ;;
    *) die "Команда: menu|install|update|apply|status|preflight|selftest|panel-set|ensure-panel|check-node-api|allow-add|deny-add|uninstall|rollback|backend-switch|migrate-inplace|rkn-enable|rkn-disable" ;;
  esac
}

if [ "${REMNA_SECURITY_SOURCE_ONLY:-0}" != 1 ]; then
  main "$@"
fi
