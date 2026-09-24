#!/usr/bin/env bash
set -Eeuo pipefail
case "${TERM:-}" in ""|dumb|unknown) export TERM=xterm ;; esac

REPO_DIR="${REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
FULL="${FULL:-$REPO_DIR/full-clean-reinstall.sh}"
V2="${V2:-$REPO_DIR/next-installer/existing-node-v2-cleanup.sh}"
PROTECTION="${PROTECTION:-$REPO_DIR/protection-manager.sh}"
TELEMT="${TELEMT:-$REPO_DIR/next-installer/telemt-manager.sh}"

NODE_DOMAIN="${NODE_DOMAIN:-}"
OLD_NODE_DOMAIN="${OLD_NODE_DOMAIN:-}"
PANEL_IP="${PANEL_IP:-}"
NODE_PORT="${NODE_PORT:-2222}"
TRANSPORT="${TRANSPORT:-combined}"
CAMOUFLAGE_MODE="${CAMOUFLAGE_MODE:-selfsteal}"
INSTALL_TELEMT="${INSTALL_TELEMT:-1}"
TELEMT_PORT="${TELEMT_PORT:-8443}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/remna-managed-rebuilds}"
SECRET_FILE="${SECRET_FILE:-/root/.remna-managed-rebuild-secret}"

say(){ printf '%s\n' "$*"; }
ok(){ printf '[OK] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
need_root(){ [ "$(id -u)" -eq 0 ] || die "run as root"; }

public_ip(){
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

discover_old_domain(){
  if [ -n "$OLD_NODE_DOMAIN" ]; then printf '%s\n' "$OLD_NODE_DOMAIN"; return; fi
  if [ -r /opt/remnanode/.node_domain ]; then tr -d '[:space:]' </opt/remnanode/.node_domain; return; fi
  grep -RhoE 'server_name[[:space:]]+[^;]+' /etc/nginx/sites-enabled /etc/nginx/sites-available 2>/dev/null |
    awk '{print $2}' | grep -E '\.' | head -1 || true
}

discover_panel_ip(){
  if [ -n "$PANEL_IP" ]; then printf '%s\n' "$PANEL_IP"; return; fi
  if [ -r /opt/remnanode/.panel_ip ]; then
    local p; p="$(tr -d '[:space:]' </opt/remnanode/.panel_ip)"
    [[ "$p" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { printf '%s\n' "$p"; return; }
  fi
  ss -tn state established "sport = :$NODE_PORT" 2>/dev/null |
    awk 'NR>1{print $5}' |
    sed -E 's/.*ffff:([^]]+)\].*/\1/; s/:.*//' |
    grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' |
    sort -u | head -1 || true
}

old_secret(){
  awk -F'SECRET_KEY=' '/SECRET_KEY=/{print $2; exit}' /opt/remnanode/docker-compose.yml 2>/dev/null |
    sed -E 's/[[:space:]]+$//'
}

discover(){
  need_root
  local p old ip
  p="$(discover_panel_ip)"
  old="$(discover_old_domain)"
  ip="$(public_ip)"
  say "NODE_DOMAIN=${NODE_DOMAIN:-<required>}"
  say "OLD_NODE_DOMAIN=${old:-<not-found>}"
  say "PUBLIC_IP=${ip:-<not-found>}"
  say "PANEL_IP=${p:-<not-found>}"
  say "NODE_PORT=$NODE_PORT"
  say "TRANSPORT=$TRANSPORT"
  say "CAMOUFLAGE_MODE=$CAMOUFLAGE_MODE"
  say "INSTALL_TELEMT=$INSTALL_TELEMT"
  [ -n "$(old_secret)" ] && say "NODE_SECRET=present" || say "NODE_SECRET=missing"
}

make_backup(){
  need_root
  local stamp dir archive old ip p
  stamp="$(date +%Y%m%d-%H%M%S)"
  dir="$BACKUP_ROOT/$stamp"
  archive="$BACKUP_ROOT/remna-managed-rebuild-$stamp.tar.gz"
  mkdir -p "$dir/files" "$dir/state"
  chmod 700 "$BACKUP_ROOT" "$dir"
  for x in /opt/remnanode /opt/remnawave-node-agent /etc/nginx /etc/letsencrypt; do
    [ -e "$x" ] && cp -a --parents "$x" "$dir/files/" 2>/dev/null || true
  done
  iptables-save >"$dir/state/iptables.v4" 2>/dev/null || true
  ip6tables-save >"$dir/state/iptables.v6" 2>/dev/null || true
  ipset save >"$dir/state/ipset.save" 2>/dev/null || true
  ufw status numbered >"$dir/state/ufw.txt" 2>/dev/null || true
  ss -lntup >"$dir/state/listeners.txt" 2>/dev/null || true
  docker ps -a --no-trunc >"$dir/state/docker-ps.txt" 2>/dev/null || true
  ip -br a >"$dir/state/ip.txt" 2>/dev/null || true
  ip route >"$dir/state/routes.txt" 2>/dev/null || true
  old="$(discover_old_domain)"; ip="$(public_ip)"; p="$(discover_panel_ip)"
  cat >"$dir/identity.txt" <<EOF
NODE_DOMAIN=$NODE_DOMAIN
OLD_NODE_DOMAIN=$old
PUBLIC_IP=$ip
PANEL_IP=$p
NODE_PORT=$NODE_PORT
EOF
  chmod 600 "$dir/identity.txt"
  tar -C "$BACKUP_ROOT" -czf "$archive" "$stamp"
  chmod 600 "$archive"
  sha256sum "$archive" >"$archive.sha256"
  chmod 600 "$archive.sha256"
  printf '%s\n' "$archive"
}

ensure_target_cert(){
  local cert="/etc/letsencrypt/live/$NODE_DOMAIN/fullchain.pem"
  local key="/etc/letsencrypt/live/$NODE_DOMAIN/privkey.pem"
  if [ -s "$cert" ] && [ -s "$key" ]; then
    ok "target certificate already exists: $NODE_DOMAIN"
    return 0
  fi
  command -v certbot >/dev/null 2>&1 || die "certbot missing"
  systemctl stop nginx >/dev/null 2>&1 || true
  if ! certbot certonly --standalone -d "$NODE_DOMAIN" --agree-tos --non-interactive       --register-unsafely-without-email --key-type ecdsa --elliptic-curve secp384r1; then
    systemctl start nginx >/dev/null 2>&1 || true
    die "certificate issuance failed"
  fi
  [ -s "$cert" ] && [ -s "$key" ] || die "certificate files missing"
}

remove_excluded_legacy(){
  if command -v docker >/dev/null 2>&1; then
    docker rm -f remnawave-node-agent >/dev/null 2>&1 || true
  fi
  rm -rf /opt/remnawave-node-agent
  systemctl disable --now nginx >/dev/null 2>&1 || true
  rm -f /etc/nginx/sites-enabled/* 2>/dev/null || true
  rm -f /etc/nginx/sites-available/cdn-xhttp.conf /etc/nginx/sites-available/default 2>/dev/null || true
  ok "legacy admin agent and host nginx configs removed; unrelated containers preserved"
}

run_base_setup(){
  local secret setup tmp
  [ -s "$SECRET_FILE" ] || die "temporary RemnaNode secret missing"
  secret="$(cat "$SECRET_FILE")"
  [ -n "$secret" ] || die "temporary RemnaNode secret empty"
  bash "$FULL" sync-source
  setup="/opt/remnanode/next-installer/setup_node-legacy.sh"
  [ -s "$setup" ] || die "synced legacy setup missing"
  tmp="$(mktemp)"
  sed '/^main$/d' "$setup" >"$tmp"
  python3 - "$tmp" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1])
s=p.read_text()
subs = [
    (r'^\s*read -p "Выберите номер версии \[1\]: " version_num\n\s*version_num=\$\{version_num:-1\}\s*$', '    version_num=1'),
    (r'^\s*read -p "Введите IP адрес панели Remnawave \(для настройки UFW\): " panel_ip\s*$', '    panel_ip="${REBUILD_PANEL_IP:?}"'),
    (r'^\s*read -p "Введите домен вашей ноды \(например, node\.example\.com\): " node_domain\s*$', '    node_domain="${REBUILD_NODE_DOMAIN:?}"'),
    (r'^\s*read -p "Порт управления нодой \(для панели\) \[2222\]: " node_port\n\s*node_port=\$\{node_port:-2222\}\s*$', '    node_port="${REBUILD_NODE_PORT:-2222}"'),
    (r'^\s*read -p "Желаете открыть дополнительные входящие порты для Xray в UFW\? \(через пробел, например: 8443 2053\) \[Нет\]: " add_ports_choice\n\s*add_ports_choice=\$\{add_ports_choice:-""\}\s*$', '    add_ports_choice=""'),
    (r'^\s*read -p "Выберите метод выпуска \[2\]: " ssl_method\n\s*ssl_method=\$\{ssl_method:-2\}\s*$', '    ssl_method=4'),
    (r'^\s*read -rp "Путь к fullchain\.pem: " source_cert\s*$', '            source_cert="${REBUILD_CERT_FULLCHAIN:?}"'),
    (r'^\s*read -rp "Путь к privkey\.pem: " source_key\s*$', '            source_key="${REBUILD_CERT_KEY:?}"'),
]
for pat,repl in subs:
    s, n = re.subn(pat, repl, s, count=1, flags=re.M)
    if n != 1:
        raise SystemExit(f"noninteractive patch regex missing: {pat[:60]}")
start = s.find('    local certificate=""')
end = s.find('    local secret_key_value;', start)
if start < 0 or end < 0:
    raise SystemExit("certificate prompt block markers not found")
s = s[:start] + '    local certificate\n    certificate="$(cat "$REBUILD_SECRET_FILE")"\n\n' + s[end:]
s, n = re.subn(r'pause_prompt\\(\\) \\{\\n    echo ""\\n    read -p "Нажмите Enter, чтобы вернуться в меню\\.\\.\\." _\\n\\}', 'pause_prompt() { return 0; }', s, count=1)
if n != 1:
    raise SystemExit("pause_prompt block not found")
p.write_text(s)
PY
  cat >>"$tmp" <<'EOF'
check_os
detect_arch
run_initial_setup
EOF
  chmod 700 "$tmp"
  ok "legacy setup wrapper prepared"
  local setup_log=/root/remna-managed-rebuild-setup.log
  REBUILD_PANEL_IP="$PANEL_IP" \
  REBUILD_NODE_DOMAIN="$NODE_DOMAIN" \
  REBUILD_NODE_PORT="$NODE_PORT" \
  REBUILD_SECRET_FILE="$SECRET_FILE" \
  REBUILD_CERT_FULLCHAIN="/etc/letsencrypt/live/$NODE_DOMAIN/fullchain.pem" \
  REBUILD_CERT_KEY="/etc/letsencrypt/live/$NODE_DOMAIN/privkey.pem" \
  bash "$tmp" </dev/null >"$setup_log" 2>&1 || {
    warn "legacy setup failed; tail follows"
    tail -80 "$setup_log" >&2 || true
    return 1
  }
  ok "legacy base setup complete"
  rm -f "$tmp" "$SECRET_FILE"
  unset secret
}
install_current_protection(){
  [ -f "$PROTECTION" ] || die "protection manager missing"
  chmod 700 "$PROTECTION" "$REPO_DIR/security/remna-security.sh" 2>/dev/null || true
  bash "$PROTECTION" install
  bash "$PROTECTION" panel-set "$PANEL_IP"
  bash "$PROTECTION" selftest
}

install_telemt(){
  [ "$INSTALL_TELEMT" = 1 ] || return 0
  [ -f "$TELEMT" ] || die "Telemt manager missing"
  chmod 700 "$TELEMT" "$REPO_DIR/next-installer/telemt-legacy-rkn-adapter.sh" 2>/dev/null || true
  local cred pass
  cred=/root/telemt-panel-credentials.txt
  if [ ! -s "$cred" ]; then
    umask 077
    pass="$(openssl rand -hex 16)"
    printf 'username=admin\npassword=%s\n' "$pass" >"$cred"
    unset pass
  fi
  pass="$(sed -n 's/^password=//p' "$cred")"
  TLS_DOMAIN="$NODE_DOMAIN" PANEL_USERNAME=admin PANEL_PASSWORD="$pass" TELEMT_PORT="$TELEMT_PORT" bash "$TELEMT" install
  unset pass
}

postcheck(){
  local fail=0
  systemctl is-active --quiet ssh || systemctl is-active --quiet sshd || { warn "SSH inactive"; fail=1; }
  docker ps --format '{{.Names}}' | grep -qx remnanode || { warn "remnanode missing"; fail=1; }
  ss -lntup | grep -q ":$NODE_PORT " || { warn "node port missing"; fail=1; }
  [ "$(cat /opt/remnanode/.node_domain 2>/dev/null)" = "$NODE_DOMAIN" ] || { warn "node domain mismatch"; fail=1; }
  [ "$(cat /opt/remnanode/.panel_ip 2>/dev/null)" = "$PANEL_IP" ] || { warn "panel ip mismatch"; fail=1; }
  bash "$PROTECTION" status >/dev/null || { warn "protection status failed"; fail=1; }
  if [ "$INSTALL_TELEMT" = 1 ]; then
    systemctl is-active --quiet telemt.service || { warn "telemt inactive"; fail=1; }
    systemctl is-active --quiet telemt-panel.service || { warn "telemt panel inactive"; fail=1; }
  fi
  docker ps --format '{{.Names}}' | grep -qx beszel-agent && ok "beszel-agent preserved" || warn "beszel-agent not present"
  if [ "$fail" -eq 0 ]; then ok "managed rebuild postcheck PASS"; else return 1; fi
}

finish_install(){
  run_base_setup
  bash "$FULL" selfsteal ensure
  CAMOUFLAGE_MODE="$CAMOUFLAGE_MODE" bash "$FULL" transport "$TRANSPORT"
  bash "$FULL" bbr-tune
  install_current_protection
  install_telemt
  postcheck
}

resume(){
  need_root
  [ -n "$NODE_DOMAIN" ] || die "set NODE_DOMAIN"
  PANEL_IP="$(discover_panel_ip)"
  [[ "$PANEL_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "PANEL_IP could not be determined safely"
  [ -s "$SECRET_FILE" ] || die "resume secret file missing: $SECRET_FILE"
  finish_install
  ok "rebuild resumed and complete: $NODE_DOMAIN"
}

rebuild(){
  need_root
  [ -n "$NODE_DOMAIN" ] || die "set NODE_DOMAIN"
  PANEL_IP="$(discover_panel_ip)"
  [[ "$PANEL_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "PANEL_IP could not be determined safely"
  local secret
  secret="$(old_secret)"
  [ -n "$secret" ] || die "old RemnaNode secret missing"
  umask 077
  printf '%s' "$secret" >"$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
  unset secret
  local backup
  backup="$(make_backup)"
  ok "backup: $backup"
  ensure_target_cert
  remove_excluded_legacy
  V2_ASSUME_YES=1 bash "$V2"
  finish_install
  ok "rebuild complete: $NODE_DOMAIN"
}

case "${1:-discover}" in
  discover) discover ;;
  backup) make_backup ;;
  rebuild) rebuild ;;
  resume) resume ;;
  status) postcheck ;;
  *) die "Usage: $0 {discover|backup|rebuild|resume|status}" ;;
esac
