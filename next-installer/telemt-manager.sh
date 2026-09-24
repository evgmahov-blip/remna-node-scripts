#!/usr/bin/env bash
set -Eeuo pipefail

TELEMT_VERSION="3.5.7"
PANEL_VERSION="v1.0.0-rc.2"
TELEMT_PORT="${TELEMT_PORT:-8443}"
TLS_DOMAIN="${TLS_DOMAIN:-}"
PANEL_USERNAME="${PANEL_USERNAME:-admin}"
PANEL_PASSWORD_HASH="${PANEL_PASSWORD_HASH:-}"
PANEL_PASSWORD="${PANEL_PASSWORD:-}"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PROTECTION_MANAGER="${PROTECTION_MANAGER:-$ROOT_DIR/protection-manager.sh}"
PROTECTION_CONF="${PROTECTION_CONF:-/opt/remna-protection/settings.conf}"
LEGACY_ADAPTER="${LEGACY_ADAPTER:-$ROOT_DIR/next-installer/telemt-legacy-rkn-adapter.sh}"

TELEMT_BIN="/usr/local/bin/telemt"
PANEL_BIN="/usr/local/bin/telemt-panel"
TELEMT_ETC="/etc/telemt"
PANEL_ETC="/etc/telemt-panel"
TELEMT_DATA="/var/lib/telemt"
PANEL_DATA="/var/lib/telemt-panel"

die(){ echo "[ERROR] $*" >&2; exit 1; }
info(){ echo "[INFO] $*"; }

need_root(){ [ "$(id -u)" -eq 0 ] || die "run as root"; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

arch_name(){
  case "$(uname -m)" in
    x86_64|amd64) echo x86_64 ;;
    aarch64|arm64) echo aarch64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

sha_telemt(){
  case "$(arch_name)" in
    x86_64) echo "c88656514164dbae64aac68341548b95586a3898df851dad837973752e405864" ;;
    aarch64) echo "2cd4d501d0524de7deec0fa5de7665d784c653c50d03cdb90ce7b6b88bc270c7" ;;
  esac
}

sha_panel(){
  case "$(arch_name)" in
    x86_64) echo "b9039bcf1324ca121fdde8e10dd9ee94f12e6411bb7fab2b093e0f57cd71f376" ;;
    aarch64) echo "df60799c028c272f45d48d0f5fbe5c42ca46c24a45270a14a42242333e085479" ;;
  esac
}

port_in_use(){
  ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${1}$"
}

preflight(){
  need_cmd ss
  [[ "$TELEMT_PORT" =~ ^[0-9]+$ ]] || die "TELEMT_PORT must be numeric"
  [ "$TELEMT_PORT" -ge 1024 ] && [ "$TELEMT_PORT" -le 65535 ] || die "Telemt port must be 1024..65535 (no bind capability)"
  case "$TELEMT_PORT" in
    2222|8080|8081|9091) die "reserved local/remnanode port: $TELEMT_PORT" ;;
  esac
  [ "$TELEMT_PORT" -ne 80 ] && [ "$TELEMT_PORT" -ne 443 ] || die "80/443 are intentionally forbidden for coexistence"
  if port_in_use "$TELEMT_PORT"; then
    die "TCP/$TELEMT_PORT is already in use"
  fi
  for p in 8080 9091; do
    if port_in_use "$p"; then
      die "loopback service port TCP/$p is already in use"
    fi
  done
  info "preflight OK: TCP/$TELEMT_PORT free; 80/443 untouched; panel/API loopback ports free"
}

ensure_protection_port(){
  local ports next
  if [ -x "$PROTECTION_MANAGER" ] && [ -f "$PROTECTION_CONF" ]; then
    ports="$(awk -F= '$1=="FILTER_PORTS"{print $2; exit}' "$PROTECTION_CONF")"
    [ -n "$ports" ] || ports="443"
    case ",$ports," in
      *,"$TELEMT_PORT",*) next="$ports" ;;
      *) next="$ports,$TELEMT_PORT" ;;
    esac
    "$PROTECTION_MANAGER" preflight >/dev/null
    "$PROTECTION_MANAGER" config-set FILTER_PORTS "$next" >/dev/null
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
      if ! ufw status | grep -Eq "^$TELEMT_PORT/tcp[[:space:]]+ALLOW IN"; then
        ufw allow "$TELEMT_PORT/tcp" comment 'Telemt MTProto' >/dev/null
      fi
    fi
    info "RemnaNode protection covers TCP/$TELEMT_PORT (FILTER_PORTS=$next); UFW admission ensured"
    return 0
  fi
  [ -f "$LEGACY_ADAPTER" ] || die "no supported RemnaNode protection manager found"
  TELEMT_PORT="$TELEMT_PORT" bash "$LEGACY_ADAPTER" apply
  info "legacy RemnaNode RKN guard covers TCP/$TELEMT_PORT"
}

download_checked(){
  local url="$1" expected="$2" out="$3"
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 --retry 3 "$url" -o "$out"
  echo "$expected  $out" | sha256sum -c - >/dev/null
}

install_tar_binary(){
  local url="$1" sha="$2" binary_name="$3" target="$4"
  local tmpd archive
  tmpd="$(mktemp -d)"
  archive="$tmpd/pkg.tar.gz"
  trap 'rm -rf "$tmpd"' RETURN
  download_checked "$url" "$sha" "$archive"
  tar -xzf "$archive" -C "$tmpd"
  [ -f "$tmpd/$binary_name" ] || die "archive does not contain $binary_name"
  install -o root -g root -m 0755 "$tmpd/$binary_name" "$target"
  rm -rf "$tmpd"
  trap - RETURN
}

ensure_user(){
  local user="$1" home="$2"
  if ! id "$user" >/dev/null 2>&1; then
    useradd --system --user-group --home-dir "$home" --create-home --shell /usr/sbin/nologin "$user"
  fi
}

install_all(){
  need_root
  need_cmd curl
  need_cmd sha256sum
  need_cmd tar
  need_cmd openssl
  preflight
  [ -n "$TLS_DOMAIN" ] || die "set TLS_DOMAIN to the Fake-TLS/SNI domain"
  [[ "$TLS_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "TLS_DOMAIN contains unsupported characters"
  [ -n "$PANEL_PASSWORD_HASH" ] || [ -n "$PANEL_PASSWORD" ] || die "set PANEL_PASSWORD_HASH or PANEL_PASSWORD"

  local arch secret telemt_url panel_url
  arch="$(arch_name)"
  secret="$(openssl rand -hex 16)"
  telemt_url="https://github.com/telemt/telemt/releases/download/${TELEMT_VERSION}/telemt-${arch}-linux-gnu.tar.gz"
  panel_url="https://github.com/amirotin/telemt_panel/releases/download/${PANEL_VERSION}/telemt-panel-${arch}-linux-gnu.tar.gz"

  install_tar_binary "$telemt_url" "$(sha_telemt)" telemt "$TELEMT_BIN"
  install_tar_binary "$panel_url" "$(sha_panel)" telemt-panel "$PANEL_BIN"
  if [ -z "$PANEL_PASSWORD_HASH" ]; then
    PANEL_PASSWORD_HASH="$(printf '%s\n' "$PANEL_PASSWORD" | "$PANEL_BIN" hash-password | tail -n 1)"
  fi
  unset PANEL_PASSWORD

  ensure_user telemt "$TELEMT_DATA"
  ensure_user telemt-panel "$PANEL_DATA"
  install -d -o telemt -g telemt -m 0750 "$TELEMT_ETC" "$TELEMT_DATA"
  install -d -o telemt-panel -g telemt-panel -m 0750 "$PANEL_ETC" "$PANEL_DATA"

  cat >"$TELEMT_ETC/telemt.toml" <<EOF
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[server]
port = $TELEMT_PORT

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32"]
minimal_runtime_enabled = false

[server.conntrack_control]
mode = "tracked"
inline_conntrack_control = false

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "$TLS_DOMAIN"
mask = true
tls_emulation = true
tls_front_dir = "$TELEMT_DATA/tlsfront"

[access.users]
default = "$secret"
EOF
  chown telemt:telemt "$TELEMT_ETC/telemt.toml"
  chmod 0600 "$TELEMT_ETC/telemt.toml"

  cat >"$PANEL_ETC/config.toml" <<EOF
listen = "127.0.0.1:8080"
data_dir = "$PANEL_DATA"
trusted_proxies = []

[tls]
mode = "http"

[telemt]
url = "http://127.0.0.1:9091"
auth_header = ""

[auth]
disabled = false
username = "$PANEL_USERNAME"
password_hash = "$PANEL_PASSWORD_HASH"

[store]
driver = "sqlite"
path = "$PANEL_DATA/panel.db"

[subpage]
enabled = false
listen = "127.0.0.1:8081"
base_path = "/sub"
public_url = ""

[subpage.tls]
mode = "http"

[host]
service_manager = "none"

[privileges]
mode = "manual"

[updates]
telemt_repo = "telemt/telemt"
panel_repo = "amirotin/telemt_panel"
telemt_binary_path = "$TELEMT_BIN"
panel_binary_path = "$PANEL_BIN"
EOF
  chown telemt-panel:telemt-panel "$PANEL_ETC/config.toml"
  chmod 0600 "$PANEL_ETC/config.toml"

  cat >/etc/systemd/system/telemt.service <<EOF
[Unit]
Description=Telemt MTProto proxy (isolated RemnaNode optional service)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=$TELEMT_DATA
ExecStart=$TELEMT_BIN $TELEMT_ETC/telemt.toml
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
ReadWritePaths=$TELEMT_DATA
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/telemt-panel.service <<EOF
[Unit]
Description=Telemt Panel (loopback-only)
After=network-online.target telemt.service
Wants=network-online.target

[Service]
Type=simple
User=telemt-panel
Group=telemt-panel
WorkingDirectory=$PANEL_DATA
ExecStart=$PANEL_BIN --config $PANEL_ETC/config.toml
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
ReadWritePaths=$PANEL_DATA $PANEL_ETC
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  ensure_protection_port
  systemctl enable --now telemt.service telemt-panel.service

  info "installed Telemt ${TELEMT_VERSION} on TCP/$TELEMT_PORT"
  info "installed Telemt Panel ${PANEL_VERSION} on 127.0.0.1:8080"
  info "firewall ownership stays with RemnaNode protection; TCP/$TELEMT_PORT was added through protection-manager"
  info "admin access: ssh -L 8080:127.0.0.1:8080 <node> then open http://127.0.0.1:8080"
  info "MTProto secret stored only in $TELEMT_ETC/telemt.toml (0600)"
}

status_all(){
  local node_host panel_user panel_driver panel_db
  node_host="$(hostname -f 2>/dev/null || hostname)"
  panel_user="$(awk -F= '/^[[:space:]]*username[[:space:]]*=/{gsub(/[[:space:]"]/,"",$2); print $2; exit}' "$PANEL_ETC/config.toml" 2>/dev/null || true)"
  panel_driver="$(awk -F= '/^[[:space:]]*driver[[:space:]]*=/{gsub(/[[:space:]"]/,"",$2); print $2; exit}' "$PANEL_ETC/config.toml" 2>/dev/null || true)"
  panel_db="$(awk -F= '/^[[:space:]]*path[[:space:]]*=/{sub(/^[[:space:]]*/,"",$2); gsub(/"/,"",$2); print $2; exit}' "$PANEL_ETC/config.toml" 2>/dev/null || true)"
  [ -n "$panel_user" ] || panel_user="$PANEL_USERNAME"
  [ -n "$panel_driver" ] || panel_driver="sqlite"
  [ -n "$panel_db" ] || panel_db="$PANEL_DATA/panel.db"

  echo "Telemt versions:"
  "$TELEMT_BIN" --version 2>/dev/null || true
  "$PANEL_BIN" --version 2>/dev/null || true
  echo
  echo "================ TELEMT PANEL ACCESS ================"
  echo "Panel bind:      http://127.0.0.1:8080"
  echo "SSH tunnel:      ssh -L 8080:127.0.0.1:8080 root@$node_host"
  echo "Open locally:    http://127.0.0.1:8080"
  echo "Username:        $panel_user"
  echo "Password:        not stored in plaintext; only bcrypt hash is kept"
  echo "Panel config:    $PANEL_ETC/config.toml"
  echo "Panel data:      $PANEL_DATA"
  echo "Panel DB:        $panel_driver — $panel_db"
  echo "Telemt config:   $TELEMT_ETC/telemt.toml"
  echo "Telemt API:      http://127.0.0.1:9091 (loopback only)"
  echo "MTProto port:    TCP/$TELEMT_PORT"
  echo "====================================================="
  echo
  ss -ltnp 2>/dev/null | grep -E "(:${TELEMT_PORT}|:8080|:9091)[[:space:]]" || true
  echo
  systemctl --no-pager --full status telemt.service telemt-panel.service 2>/dev/null || true
}

disable_all(){
  need_root
  systemctl disable --now telemt-panel.service telemt.service || true
  info "services disabled; data/config preserved; firewall untouched"
}

uninstall_all(){
  need_root
  disable_all
  rm -f /etc/systemd/system/telemt.service /etc/systemd/system/telemt-panel.service
  systemctl daemon-reload
  rm -f "$TELEMT_BIN" "$PANEL_BIN"
  info "binaries and units removed; configs/data preserved in $TELEMT_ETC, $PANEL_ETC, $TELEMT_DATA, $PANEL_DATA"
}

case "${1:-help}" in
  preflight) preflight ;;
  install) install_all ;;
  status) status_all ;;
  disable) disable_all ;;
  uninstall) uninstall_all ;;
  *)
    cat <<EOF
Usage: $0 {preflight|install|status|disable|uninstall}

Safe coexistence defaults:
  TELEMT_PORT=8443
  Panel       127.0.0.1:8080
  Telemt API  127.0.0.1:9091
  Firewall    managed only through RemnaNode protection-manager
  80/443      never claimed by this module

Install requires:
  TLS_DOMAIN=example.org
  PANEL_PASSWORD='<strong one-time password>'
  # or PANEL_PASSWORD_HASH='<bcrypt hash>'
Optional:
  PANEL_USERNAME=admin
  TELEMT_PORT=8443
EOF
    ;;
esac
