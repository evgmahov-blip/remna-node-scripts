#!/usr/bin/env bash
set -Eeuo pipefail

APP=remna-protection
BASE=/opt/remna-protection
CONF=$BASE/settings.conf
DATA=$BASE/data
LOGDIR=/var/log/remna-protection
UPDATE_LOG=$LOGDIR/update.log
ACTION_LOG=$LOGDIR/actions.log
SERVICE=/etc/systemd/system/remna-protection.service
UPDATE_SERVICE=/etc/systemd/system/remna-protection-update.service
UPDATE_TIMER=/etc/systemd/system/remna-protection-update.timer
CHAIN=REMNA_GUARD
CHAIN6=REMNA_GUARD6
SET_TSPU=REMNA_TSPU
SET_GOV=REMNA_GOV
SET_ALLOW=REMNA_ALLOW
SET_DENY=REMNA_DENY
SET_COUNTRY=REMNA_COUNTRY_ALLOW
TSPU_URL=https://raw.githubusercontent.com/tread-lightly/CyberOK_Skipa_ips/main/lists/skipa_cidr.txt
GOV_URL=https://raw.githubusercontent.com/C24Be/AS_Network_List/main/blacklists_iptables/blacklist-v4.ipset

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO=sudo; fi
TTY=/dev/tty; { [ -r "$TTY" ] && [ -w "$TTY" ]; } || TTY=/dev/stdin
say(){ printf '%s\n' "$*"; }
ok(){ printf '✓ %s\n' "$*"; }
warn(){ printf '! %s\n' "$*" >&2; }
die(){ printf '✗ %s\n' "$*" >&2; exit 1; }
log(){ $SUDO install -d -m 0755 "$LOGDIR"; printf '[%s] %s\n' "$(date '+%F %T')" "$*" | $SUDO tee -a "$ACTION_LOG" >/dev/null; }

need_root(){ [ -z "$SUDO" ] || $SUDO -v; }
ensure_dirs(){ $SUDO install -d -o root -g root -m 0700 "$BASE" "$DATA"; $SUDO install -d -o root -g root -m 0755 "$LOGDIR"; }

valid_ip(){ python3 - "$1" <<'PY'
import ipaddress,sys
try: ipaddress.ip_address(sys.argv[1]); raise SystemExit(0)
except Exception: raise SystemExit(1)
PY
}
valid_cidr(){ python3 - "$1" <<'PY'
import ipaddress,sys
try: ipaddress.ip_network(sys.argv[1], strict=False); raise SystemExit(0)
except Exception: raise SystemExit(1)
PY
}
ip_version(){ python3 - "$1" <<'PY'
import ipaddress,sys
print(ipaddress.ip_address(sys.argv[1]).version)
PY
}
valid_ports(){
  python3 - "$1" <<'PY'
import sys
raw=sys.argv[1].strip()
try:
    vals=[int(x.strip()) for x in raw.split(',') if x.strip()]
    ok=bool(vals) and len(vals)<=15 and all(1<=x<=65535 for x in vals)
except Exception: ok=False
raise SystemExit(0 if ok else 1)
PY
}

write_defaults(){
  ensure_dirs
  if [ ! -f "$CONF" ]; then
    $SUDO tee "$CONF" >/dev/null <<'EOF'
PANEL_IP=
ENABLE_TSPU=1
ENABLE_GOV=1
ENABLE_GEOIP=0
FILTER_PORTS=443,18443,5222,5223,8530
GEO_COUNTRIES=
EOF
    $SUDO chmod 0600 "$CONF"
  fi
  for f in allow.txt deny.txt countries.txt tspu.txt gov.txt; do $SUDO touch "$DATA/$f"; done
  $SUDO chmod 0600 "$DATA"/*.txt
}

load_conf(){
  write_defaults
  # shellcheck disable=SC1090
  . "$CONF"
  PANEL_IP=${PANEL_IP:-}
  ENABLE_TSPU=${ENABLE_TSPU:-1}
  ENABLE_GOV=${ENABLE_GOV:-1}
  ENABLE_GEOIP=${ENABLE_GEOIP:-0}
  FILTER_PORTS=${FILTER_PORTS:-443,18443,5222,5223,8530}
  GEO_COUNTRIES=${GEO_COUNTRIES:-}
}

set_conf(){
  local key=$1 value=$2 tmp
  tmp=$(mktemp)
  awk -F= -v k="$key" -v v="$value" 'BEGIN{done=0} $1==k{print k"="v;done=1;next}{print} END{if(!done)print k"="v}' "$CONF" > "$tmp"
  $SUDO install -o root -g root -m 0600 "$tmp" "$CONF"
  rm -f "$tmp"
}

install_deps(){
  local miss=() p
  for p in curl ipset iptables python3; do command -v "$p" >/dev/null 2>&1 || miss+=("$p"); done
  if [ ${#miss[@]} -gt 0 ]; then
    $SUDO apt-get update -y
    $SUDO apt-get install -y curl ipset iptables python3
  fi
  command -v ipset >/dev/null || die "ipset не установлен."
  local test="REMNA_TEST_$$"
  $SUDO ipset create "$test" hash:ip family inet maxelem 8 -exist >/dev/null 2>&1 || die "Ядро не поддерживает ipset/xt_set."
  $SUDO ipset destroy "$test" >/dev/null 2>&1 || true
}

sanitize_cidrs(){
  local src=$1 dst=$2 mode=${3:-plain}
  python3 - "$src" "$dst" "$mode" <<'PY'
import ipaddress,re,sys
src,dst,mode=sys.argv[1:]
out=set()
for raw in open(src,encoding='utf-8',errors='ignore'):
    s=raw.strip()
    if not s or s.startswith('#'): continue
    vals=re.findall(r'(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?',s) if mode=='gov' else [s.split()[0]]
    for v in vals:
        try:
            n=ipaddress.ip_network(v,strict=False)
            if n.version==4: out.add(str(n))
        except Exception: pass
with open(dst,'w',encoding='utf-8') as f:
    for x in sorted(out,key=lambda x:(int(ipaddress.ip_network(x).network_address),ipaddress.ip_network(x).prefixlen)): f.write(x+'\n')
PY
}

atomic_load_set(){
  local target file max tmp restore count
  target=$1
  file=$2
  max=${3:-2000000}
  tmp="${target}_TMP"
  count=$(grep -cve '^[[:space:]]*$' "$file" 2>/dev/null || true)
  [ "$count" -gt 0 ] || return 1
  restore=$(mktemp)
  {
    printf 'create %s hash:net family inet maxelem %s -exist\n' "$tmp" "$max"
    printf 'flush %s\n' "$tmp"
    while IFS= read -r x; do [ -n "$x" ] && printf 'add %s %s\n' "$tmp" "$x"; done < "$file"
  } > "$restore"
  $SUDO ipset restore < "$restore" || { rm -f "$restore"; return 1; }
  rm -f "$restore"
  $SUDO ipset create "$target" hash:net family inet maxelem "$max" -exist
  $SUDO ipset swap "$tmp" "$target"
  $SUDO ipset destroy "$tmp" >/dev/null 2>&1 || true
}

ensure_set(){ $SUDO ipset create "$1" hash:net family inet maxelem "${2:-2000000}" -exist >/dev/null; }

update_blocklists(){
  need_root; load_conf; install_deps
  [ -n "$PANEL_IP" ] && valid_ip "$PANEL_IP" || die "PANEL_IP не задан/некорректен. Сначала: protection-manager.sh panel-set <IP>."
  local raw san good=0
  raw=$(mktemp); san=$(mktemp)
  if curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 "$TSPU_URL" -o "$raw"; then
    sanitize_cidrs "$raw" "$san" plain
    if [ -s "$san" ]; then $SUDO install -m 0600 "$san" "$DATA/tspu.txt"; atomic_load_set "$SET_TSPU" "$DATA/tspu.txt" && good=$((good+1)); fi
  else warn "TSPU list: скачать не удалось, оставляю старый набор."; fi
  if curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 "$GOV_URL" -o "$raw"; then
    sanitize_cidrs "$raw" "$san" gov
    if [ -s "$san" ]; then $SUDO install -m 0600 "$san" "$DATA/gov.txt"; atomic_load_set "$SET_GOV" "$DATA/gov.txt" && good=$((good+1)); fi
  else warn "GOV list: скачать не удалось, оставляю старый набор."; fi
  rm -f "$raw" "$san"
  apply_rules
  printf '[%s] updated sources=%s\n' "$(date '+%F %T')" "$good" | $SUDO tee -a "$UPDATE_LOG" >/dev/null
  ok "Блок-листы обновлены атомарно."
}

build_geo_country_file(){
  load_conf
  local out tmp code
  out=$(mktemp); : > "$out"
  IFS=',' read -ra cc <<< "$GEO_COUNTRIES"
  for code in "${cc[@]}"; do
    code=$(printf '%s' "$code" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    [ -n "$code" ] || continue
    tmp=$(mktemp)
    if curl -fsSL --connect-timeout 10 --max-time 30 "https://www.ipdeny.com/ipblocks/data/aggregated/${code}-aggregated.zone" -o "$tmp"; then cat "$tmp" >> "$out"; fi
    rm -f "$tmp"
  done
  if [ -s "$out" ]; then
    local san; san=$(mktemp); sanitize_cidrs "$out" "$san" plain; $SUDO install -m 0600 "$san" "$DATA/countries.txt"; rm -f "$san"
  fi
  rm -f "$out"
}

remove_jump_all(){
  while $SUDO iptables -C INPUT -j "$CHAIN" >/dev/null 2>&1; do $SUDO iptables -D INPUT -j "$CHAIN"; done
  if command -v ip6tables >/dev/null; then while $SUDO ip6tables -C INPUT -j "$CHAIN6" >/dev/null 2>&1; do $SUDO ip6tables -D INPUT -j "$CHAIN6"; done; fi
}

sync_ufw_2222(){
  command -v ufw >/dev/null 2>&1 || return 0
  $SUDO ufw status 2>/dev/null | grep -qi '^Status: active' || return 0
  while $SUDO ufw status 2>/dev/null | grep -Eq '^2222/tcp[[:space:]]+ALLOW([[:space:]]+IN)?[[:space:]]+Anywhere'; do
    $SUDO ufw --force delete allow 2222/tcp >/dev/null 2>&1 || break
  done
  if [ "$(ip_version "$PANEL_IP")" = 4 ]; then
    $SUDO ufw allow from "$PANEL_IP" to any port 2222 proto tcp comment 'Remnawave panel only' >/dev/null 2>&1 || true
  fi
}

apply_rules(){
  need_root; load_conf; install_deps
  [ -n "$PANEL_IP" ] && valid_ip "$PANEL_IP" || die "PANEL_IP не задан/некорректен: отказываюсь менять firewall, чтобы не отрезать панель."
  valid_ports "$FILTER_PORTS" || die "FILTER_PORTS некорректен (1..65535, максимум 15 портов для multiport)."
  ensure_set "$SET_TSPU"; ensure_set "$SET_GOV"; ensure_set "$SET_ALLOW" 65536; ensure_set "$SET_DENY" 65536; ensure_set "$SET_COUNTRY" 3000000
  [ -s "$DATA/tspu.txt" ] && atomic_load_set "$SET_TSPU" "$DATA/tspu.txt" || true
  [ -s "$DATA/gov.txt" ] && atomic_load_set "$SET_GOV" "$DATA/gov.txt" || true
  [ -s "$DATA/allow.txt" ] && atomic_load_set "$SET_ALLOW" "$DATA/allow.txt" 65536 || true
  [ -s "$DATA/deny.txt" ] && atomic_load_set "$SET_DENY" "$DATA/deny.txt" 65536 || true
  if [ "$ENABLE_GEOIP" = 1 ]; then build_geo_country_file || true; [ -s "$DATA/countries.txt" ] && atomic_load_set "$SET_COUNTRY" "$DATA/countries.txt" 3000000 || true; fi

  $SUDO iptables -N "$CHAIN" >/dev/null 2>&1 || true; $SUDO iptables -F "$CHAIN"
  if [ "$(ip_version "$PANEL_IP")" = 4 ]; then $SUDO iptables -A "$CHAIN" -p tcp -s "$PANEL_IP" --dport 2222 -j ACCEPT; fi
  $SUDO iptables -A "$CHAIN" -p tcp --dport 2222 -j DROP
  $SUDO iptables -A "$CHAIN" -m set --match-set "$SET_ALLOW" src -j ACCEPT
  $SUDO iptables -A "$CHAIN" -m set --match-set "$SET_DENY" src -j DROP
  local ports=${FILTER_PORTS// /}
  if [ "$ENABLE_TSPU" = 1 ]; then $SUDO iptables -A "$CHAIN" -p tcp -m multiport --dports "$ports" -m set --match-set "$SET_TSPU" src -j DROP; fi
  if [ "$ENABLE_GOV" = 1 ]; then $SUDO iptables -A "$CHAIN" -p tcp -m multiport --dports "$ports" -m set --match-set "$SET_GOV" src -j DROP; fi
  if [ "$ENABLE_GEOIP" = 1 ] && [ -s "$DATA/countries.txt" ]; then
    $SUDO iptables -A "$CHAIN" -p tcp -m multiport --dports "$ports" -m set --match-set "$SET_COUNTRY" src -j ACCEPT
    $SUDO iptables -A "$CHAIN" -p tcp -m multiport --dports "$ports" -j DROP
  fi
  $SUDO iptables -A "$CHAIN" -j RETURN

  if command -v ip6tables >/dev/null 2>&1; then
    $SUDO ip6tables -N "$CHAIN6" >/dev/null 2>&1 || true; $SUDO ip6tables -F "$CHAIN6"
    if [ "$(ip_version "$PANEL_IP")" = 6 ]; then $SUDO ip6tables -A "$CHAIN6" -p tcp -s "$PANEL_IP" --dport 2222 -j ACCEPT; fi
    $SUDO ip6tables -A "$CHAIN6" -p tcp --dport 2222 -j DROP
    $SUDO ip6tables -A "$CHAIN6" -j RETURN
  fi
  remove_jump_all
  $SUDO iptables -I INPUT 1 -j "$CHAIN"
  command -v ip6tables >/dev/null 2>&1 && $SUDO ip6tables -I INPUT 1 -j "$CHAIN6" || true
  sync_ufw_2222
  log "rules applied panel=$PANEL_IP ports=$FILTER_PORTS geo=$ENABLE_GEOIP"
}

set_panel_ip(){
  need_root; load_conf
  local ip=${1:-}
  if [ -z "$ip" ]; then printf 'IP панели Remnawave: '; read -r ip < "$TTY" || true; fi
  valid_ip "$ip" || die "Некорректный IP панели: $ip"
  set_conf PANEL_IP "$ip"
  apply_rules
  ok "TCP/2222 теперь разрешён только панели $ip; для остальных DROP."
}

ensure_panel_ip(){
  load_conf
  if [ -n "${PANEL_IP_ENV:-}" ]; then set_panel_ip "$PANEL_IP_ENV"; return; fi
  if [ -n "$PANEL_IP" ] && valid_ip "$PANEL_IP"; then apply_rules; return; fi
  if [ -n "${PANEL_IP_OVERRIDE:-}" ]; then set_panel_ip "$PANEL_IP_OVERRIDE"; return; fi
  if [ -t 0 ] || [ "$TTY" = /dev/tty ]; then
    warn "Порт 2222 нельзя оставлять открытым всем. Укажи IP сервера панели."
    set_panel_ip
  else
    warn "PANEL_IP не задан: firewall не меняю, чтобы не отрезать панель. Передай PANEL_IP_ENV=x.x.x.x."
    return 1
  fi
}

check_node_api(){
  load_conf
  printf 'Panel IP     : %s\n' "${PANEL_IP:-НЕ ЗАДАН}"
  if [ -n "$PANEL_IP" ] && valid_ip "$PANEL_IP" && $SUDO iptables -C INPUT -j "$CHAIN" >/dev/null 2>&1 && $SUDO iptables -C "$CHAIN" -p tcp --dport 2222 -j DROP >/dev/null 2>&1; then
    if [ "$(ip_version "$PANEL_IP")" = 4 ] && ! $SUDO iptables -C "$CHAIN" -p tcp -s "$PANEL_IP" --dport 2222 -j ACCEPT >/dev/null 2>&1; then printf 'TCP/2222    : BROKEN (panel allow missing)\n'; return 1; fi
    printf 'TCP/2222    : protected (panel allow + default DROP)\n'
  else
    printf 'TCP/2222    : UNPROTECTED\n'
    return 1
  fi
}

add_ip_file(){
  local file=$1 value=$2 tmp
  valid_cidr "$value" || die "Некорректный IP/CIDR: $value"
  tmp=$(mktemp); { cat "$DATA/$file" 2>/dev/null || true; echo "$value"; } | sort -u > "$tmp"; $SUDO install -m 0600 "$tmp" "$DATA/$file"; rm -f "$tmp"; apply_rules
}
remove_ip_file(){ local file=$1 value=$2 tmp; tmp=$(mktemp); grep -vxF "$value" "$DATA/$file" > "$tmp" || true; $SUDO install -m 0600 "$tmp" "$DATA/$file"; rm -f "$tmp"; apply_rules; }

write_units(){
  ensure_dirs
  local self=/opt/remna-node-scripts/protection-manager.sh
  $SUDO tee "$SERVICE" >/dev/null <<EOF
[Unit]
Description=Remna Node protection rules
After=network-pre.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=$self apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  $SUDO tee "$UPDATE_SERVICE" >/dev/null <<EOF
[Unit]
Description=Remna protection blocklist update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$self update
EOF
  $SUDO tee "$UPDATE_TIMER" >/dev/null <<'EOF'
[Unit]
Description=Daily Remna protection update

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
RandomizedDelaySec=15m
Unit=remna-protection-update.service

[Install]
WantedBy=timers.target
EOF
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable remna-protection.service >/dev/null 2>&1 || true
  $SUDO systemctl enable --now remna-protection-update.timer >/dev/null 2>&1 || true
}

install_all(){
  need_root; write_defaults; install_deps
  ensure_panel_ip
  write_units
  update_blocklists || { warn "Списки не обновились; применяю сохранённые правила."; apply_rules; }
  ok "Защита установлена."
}

status(){
  load_conf
  echo '=== Remna protection ==='
  check_node_api || true
  printf 'TSPU         : %s (%s entries)\n' "$ENABLE_TSPU" "$($SUDO ipset list "$SET_TSPU" 2>/dev/null | awk -F': ' '/Number of entries/{print $2}' || echo 0)"
  printf 'GOV          : %s (%s entries)\n' "$ENABLE_GOV" "$($SUDO ipset list "$SET_GOV" 2>/dev/null | awk -F': ' '/Number of entries/{print $2}' || echo 0)"
  printf 'GeoIP        : %s countries=%s\n' "$ENABLE_GEOIP" "${GEO_COUNTRIES:-none}"
  printf 'Filter ports : %s\n' "$FILTER_PORTS"
  systemctl is-active remna-protection-update.timer 2>/dev/null | sed 's/^/Update timer : /' || true
}

uninstall(){
  need_root
  $SUDO systemctl disable --now remna-protection-update.timer remna-protection.service >/dev/null 2>&1 || true
  $SUDO rm -f "$SERVICE" "$UPDATE_SERVICE" "$UPDATE_TIMER"; $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
  remove_jump_all
  $SUDO iptables -F "$CHAIN" >/dev/null 2>&1 || true; $SUDO iptables -X "$CHAIN" >/dev/null 2>&1 || true
  if command -v ip6tables >/dev/null; then $SUDO ip6tables -F "$CHAIN6" >/dev/null 2>&1 || true; $SUDO ip6tables -X "$CHAIN6" >/dev/null 2>&1 || true; fi
  for s in "$SET_TSPU" "$SET_GOV" "$SET_ALLOW" "$SET_DENY" "$SET_COUNTRY"; do $SUDO ipset destroy "$s" >/dev/null 2>&1 || true; done
  ok "Правила защиты удалены. Конфиг $BASE сохранён."
}

menu(){
  while true; do
    cat <<'EOF'

────────────────────────────────────────────────────────────
Защита Remna Node
────────────────────────────────────────────────────────────
 [1] Установить/обновить защиту
 [2] Задать IP панели и закрыть 2222
 [3] Обновить TSPU/GOV блок-листы
 [4] Статус
 [5] Добавить allow IP/CIDR
 [6] Удалить allow IP/CIDR
 [7] Добавить deny IP/CIDR
 [8] Удалить deny IP/CIDR
 [9] Включить GeoIP allow-страны
 [10] Выключить GeoIP
 [11] Изменить защищаемые порты
 [12] Удалить firewall-защиту
 [0] Назад
────────────────────────────────────────────────────────────
EOF
    printf 'Выбор: '; local c v; read -r c < "$TTY" || true
    case "$c" in
      1) install_all ;;
      2) set_panel_ip ;;
      3) update_blocklists ;;
      4) status ;;
      5) printf 'IP/CIDR: '; read -r v < "$TTY"; add_ip_file allow.txt "$v" ;;
      6) printf 'IP/CIDR: '; read -r v < "$TTY"; remove_ip_file allow.txt "$v" ;;
      7) printf 'IP/CIDR: '; read -r v < "$TTY"; add_ip_file deny.txt "$v" ;;
      8) printf 'IP/CIDR: '; read -r v < "$TTY"; remove_ip_file deny.txt "$v" ;;
      9) printf 'Коды стран через запятую (например FI,DE): '; read -r v < "$TTY"; set_conf GEO_COUNTRIES "$v"; set_conf ENABLE_GEOIP 1; apply_rules ;;
      10) set_conf ENABLE_GEOIP 0; apply_rules ;;
      11) printf 'TCP-порты через запятую (до 15): '; read -r v < "$TTY"; valid_ports "$v" || { warn "Некорректный список портов."; continue; }; set_conf FILTER_PORTS "$v"; apply_rules ;;
      12) printf 'Удалить правила? Введите YES: '; read -r v < "$TTY"; [ "$v" = YES ] && uninstall ;;
      0|'') return ;;
      *) warn "Неизвестный пункт" ;;
    esac
  done
}

main(){
  case "${1:-menu}" in
    menu|'') menu ;;
    install) install_all ;;
    update) update_blocklists ;;
    apply) apply_rules ;;
    status) status ;;
    panel-set) shift; set_panel_ip "${1:-}" ;;
    ensure-panel) ensure_panel_ip ;;
    check-node-api) check_node_api ;;
    allow-add) shift; add_ip_file allow.txt "$1" ;;
    deny-add) shift; add_ip_file deny.txt "$1" ;;
    uninstall) uninstall ;;
    *) die "Команда: menu|install|update|apply|status|panel-set|ensure-panel|check-node-api|uninstall" ;;
  esac
}
main "$@"
