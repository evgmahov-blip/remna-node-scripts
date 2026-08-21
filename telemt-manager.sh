#!/usr/bin/env bash
set -Eeo pipefail

PANEL_INSTALL_URL="https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh"
TELEMT_INSTALL_URL="https://raw.githubusercontent.com/telemt/telemt/main/install.sh"
PANEL_CONFIG=/etc/telemt-panel/config.toml
PANEL_PORT=18443
PANEL_PATH=/telemt
STATE_DIR=/var/lib/remna-node-scripts
TELEMT_STATE="$STATE_DIR/telemt-integration.env"
CADDY_MARK_BEGIN="# BEGIN REMNA TELEMT PANEL"
CADDY_MARK_END="# END REMNA TELEMT PANEL"

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
TTY=/dev/tty; { [ -r "$TTY" ] && [ -w "$TTY" ]; } || TTY=/dev/stdin
say(){ printf '%s\n' "$*"; }; ok(){ printf '✓ %s\n' "$*"; }; warn(){ printf '! %s\n' "$*" >&2; }; die(){ printf '✗ %s\n' "$*" >&2; exit 1; }

panel_domain(){ local d="${DOMAIN:-}"; if [ -z "$d" ] && [ -f /etc/caddy/Caddyfile ]; then d="$(awk '/^[A-Za-z0-9.-]+[[:space:]]*\{/{gsub(/[[:space:]]*\{.*/,"",$0); print $1; exit}' /etc/caddy/Caddyfile 2>/dev/null || true)"; fi; printf '%s' "$d"; }
list_telemt_units(){ systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '$1 ~ /^telemt[0-9]*\.service$/ {print $1}' | sort -V; }
choose_existing_telemt(){
  if systemctl cat telemt1.service >/dev/null 2>&1; then printf '%s\n' 'telemt1.service|9091|/etc/telemt/telemt1.toml'; return; fi
  if systemctl cat telemt.service >/dev/null 2>&1; then printf '%s\n' 'telemt.service|9091|/etc/telemt/telemt.toml'; return; fi
  printf '||\n'
}
save_state(){ $SUDO install -d -o root -g root -m 0700 "$STATE_DIR"; printf 'MANAGED_TELEMT=%s\nMANAGED_PANEL=%s\nTELEMT_UNIT=%s\nTELEMT_API_PORT=%s\nTELEMT_CONFIG=%s\n' "$1" "$2" "$3" "$4" "$5" | $SUDO tee "$TELEMT_STATE" >/dev/null; $SUDO chmod 600 "$TELEMT_STATE"; }
load_state(){ MANAGED_TELEMT=0; MANAGED_PANEL=0; TELEMT_UNIT=""; TELEMT_API_PORT=""; TELEMT_CONFIG=""; [ -s "$TELEMT_STATE" ] && . "$TELEMT_STATE"; }

render_caddy_with_panel(){
  awk -v begin="$CADDY_MARK_BEGIN" -v end="$CADDY_MARK_END" '
    BEGIN{skip=0;inserted=0}
    index($0,begin){skip=1;next} index($0,end){skip=0;next} skip{next}
    /^[[:space:]]*handle[[:space:]]*\{[[:space:]]*$/ && !inserted {
      print "\t" begin; print "\thandle /telemt* {"; print "\t\treverse_proxy 127.0.0.1:8080"; print "\t}"; print "\t" end; print ""; inserted=1
    }
    {print}
    END{if(!inserted) exit 42}
  ' "$1" > "$2"
}
patch_caddy_file(){
  local f="$1" tmp backup; [ -f "$f" ] || return 0; tmp="$(mktemp)"; backup="${f}.telemt-backup.$(date +%Y%m%d-%H%M%S)"
  render_caddy_with_panel "$f" "$tmp" || { rm -f "$tmp"; die "Не найден безопасный handle{} для вставки Telemt в $f"; }
  $SUDO caddy validate --config "$tmp" --adapter caddyfile >/dev/null || { rm -f "$tmp"; die "Telemt-маршрут сделал $f невалидным; исходный файл не изменён."; }
  $SUDO cp -a "$f" "$backup"; $SUDO install -o root -g root -m 0644 "$tmp" "$f"; rm -f "$tmp"
}
remove_caddy_panel_block(){
  local f="$1" tmp; [ -f "$f" ] || return 0; grep -Fq "$CADDY_MARK_BEGIN" "$f" || return 0; tmp="$(mktemp)"
  awk -v begin="$CADDY_MARK_BEGIN" -v end="$CADDY_MARK_END" 'BEGIN{skip=0} index($0,begin){skip=1;next} index($0,end){skip=0;next} !skip{print}' "$f" > "$tmp"
  $SUDO caddy validate --config "$tmp" --adapter caddyfile >/dev/null || { rm -f "$tmp"; warn "Не удалось безопасно убрать Telemt-блок из $f"; return 1; }
  $SUDO install -o root -g root -m 0644 "$tmp" "$f"; rm -f "$tmp"
}
ensure_panel_caddy(){ local f; command -v caddy >/dev/null 2>&1 || die "Caddy не найден."; for f in /etc/caddy/Caddyfile /etc/caddy/Caddyfile.public /etc/caddy/Caddyfile.reality; do patch_caddy_file "$f"; done; $SUDO systemctl reload caddy >/dev/null 2>&1 || $SUDO systemctl restart caddy >/dev/null 2>&1 || true; }

configure_panel_file(){
  local unit="$1" api="$2" config="$3" tmp backup; [ -f "$PANEL_CONFIG" ] || die "Не найден $PANEL_CONFIG"
  backup="${PANEL_CONFIG}.backup.$(date +%Y%m%d-%H%M%S)"; $SUDO cp -a "$PANEL_CONFIG" "$backup"; tmp="$(mktemp)"
  awk -v unit="$unit" -v api="$api" -v cfg="$config" '
    BEGIN{sec="";base=0}
    /^\[[^]]+\]/{sec=$0}
    /^listen[[:space:]]*=/{print "listen = \"127.0.0.1:8080\"";next}
    /^base_path[[:space:]]*=|^# base_path[[:space:]]*=/{print "base_path = \"/telemt\"";base=1;next}
    /^\[telemt\]$/{if(!base){print "base_path = \"/telemt\"\n";base=1};print;sec="[telemt]";next}
    sec=="[telemt]" && /^url[[:space:]]*=/{print "url = \"http://127.0.0.1:" api "\"";next}
    sec=="[telemt]" && /^#? ?service_name[[:space:]]*=/{print "service_name = \"" unit "\"";next}
    sec=="[telemt]" && /^#? ?config_path[[:space:]]*=/{print "config_path = \"" cfg "\"";next}
    {print}
  ' "$PANEL_CONFIG" > "$tmp"
  grep -q '^service_name[[:space:]]*=' "$tmp" || sed -i "/^\[telemt\]$/a service_name = \"$unit\"" "$tmp"
  grep -q '^config_path[[:space:]]*=' "$tmp" || sed -i "/^\[telemt\]$/a config_path = \"$config\"" "$tmp"
  $SUDO install -o telemt-panel -g telemt-panel -m 0600 "$tmp" "$PANEL_CONFIG"; rm -f "$tmp"; $SUDO systemctl restart telemt-panel
  ok "Telemt Panel настроена; backup: $backup"
}
install_redirect_service(){
  command -v iptables >/dev/null 2>&1 || { $SUDO apt-get update -y; $SUDO apt-get install -y iptables; }
  cat <<UNIT | $SUDO tee /etc/systemd/system/telemt-panel-${PANEL_PORT}.service >/dev/null
[Unit]
Description=Redirect TCP/${PANEL_PORT} to TCP/443 for Telemt Panel shared TLS
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '/usr/sbin/iptables -t nat -C PREROUTING -p tcp --dport ${PANEL_PORT} -j REDIRECT --to-ports 443 2>/dev/null || /usr/sbin/iptables -t nat -A PREROUTING -p tcp --dport ${PANEL_PORT} -j REDIRECT --to-ports 443'
ExecStop=/bin/sh -c '/usr/sbin/iptables -t nat -D PREROUTING -p tcp --dport ${PANEL_PORT} -j REDIRECT --to-ports 443 2>/dev/null || true'
[Install]
WantedBy=multi-user.target
UNIT
  $SUDO systemctl daemon-reload; $SUDO systemctl enable --now "telemt-panel-${PANEL_PORT}.service"
}
open_port(){ local p="$1"; if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -qi 'Status: active'; then $SUDO ufw allow "${p}/tcp" >/dev/null; fi; }

telemt_install(){
  local detected unit api config managed_telemt=0 managed_panel=0 yn port tlsdomain tmp pdomain
  detected="$(choose_existing_telemt)"; IFS='|' read -r unit api config <<<"$detected"
  if [ -n "$unit" ]; then ok "Найден существующий $unit — не обновляю и не меняю его конфиг."; else
    printf 'Telemt не найден. Установить новый telemt.service? [y/N] '; read -r yn <"$TTY" || true; [[ "$yn" =~ ^[Yy]$ ]] || return 0
    printf 'Внешний порт Telemt [5222]: '; read -r port <"$TTY" || true; port="${port:-5222}"; [ "$port" != 443 ] || die "443 зарезервирован для REALITY/Caddy"
    printf 'Fake-TLS домен [www.apple.com]: '; read -r tlsdomain <"$TTY" || true; tlsdomain="${tlsdomain:-www.apple.com}"
    ss -ltn 2>/dev/null | grep -Eq ":${port}[[:space:]]" && die "TCP/$port уже занят"
    tmp="$(mktemp)"; curl -fsSL "$TELEMT_INSTALL_URL" -o "$tmp"; $SUDO sh "$tmp" -l ru -d "$tlsdomain" -p "$port"; rm -f "$tmp"; open_port "$port"
    unit=telemt.service; api=9091; config=/etc/telemt/telemt.toml; managed_telemt=1
  fi
  if systemctl cat telemt-panel.service >/dev/null 2>&1 && [ -f "$PANEL_CONFIG" ]; then ok "Существующая Telemt Panel найдена — не переустанавливаю."; else tmp="$(mktemp)"; curl -fsSL "$PANEL_INSTALL_URL" -o "$tmp"; $SUDO bash "$tmp"; rm -f "$tmp"; managed_panel=1; fi
  configure_panel_file "${unit%.service}" "$api" "$config"; ensure_panel_caddy; install_redirect_service; open_port "$PANEL_PORT"; save_state "$managed_telemt" "$managed_panel" "$unit" "$api" "$config"
  pdomain="$(panel_domain)"; ok "Telemt-интеграция готова."; [ -z "$pdomain" ] || say "Panel HTTPS: https://${pdomain}:${PANEL_PORT}${PANEL_PATH}/login"
}
telemt_status(){ local pdomain; say "Telemt units:"; list_telemt_units | while read -r u; do printf '  %-18s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done; say "Telemt Panel: $(systemctl is-active telemt-panel 2>/dev/null || echo absent)"; say "Порты:"; ss -ltnp 2>/dev/null | grep -E ':5222 |:5223 |:8530 |:8080 |:9091 |:9092 |:9093 |:443 ' || true; say "Redirect ${PANEL_PORT}->443:"; $SUDO iptables -t nat -S PREROUTING 2>/dev/null | grep -- "--dport ${PANEL_PORT}" || echo '  нет'; pdomain="$(panel_domain)"; [ -z "$pdomain" ] || say "URL: https://${pdomain}:${PANEL_PORT}${PANEL_PATH}/login"; }
telemt_remove(){
  local yn tmp f; load_state; printf 'Убрать интеграцию Telemt Panel (18443 + /telemt)? [y/N] '; read -r yn <"$TTY" || true; [[ "$yn" =~ ^[Yy]$ ]] || return 0
  $SUDO systemctl disable --now "telemt-panel-${PANEL_PORT}.service" >/dev/null 2>&1 || true; $SUDO rm -f "/etc/systemd/system/telemt-panel-${PANEL_PORT}.service"; $SUDO iptables -t nat -D PREROUTING -p tcp --dport "$PANEL_PORT" -j REDIRECT --to-ports 443 2>/dev/null || true
  for f in /etc/caddy/Caddyfile /etc/caddy/Caddyfile.public /etc/caddy/Caddyfile.reality; do remove_caddy_panel_block "$f" || true; done; $SUDO systemctl reload caddy >/dev/null 2>&1 || true
  warn "Существующие Telemt/Panel не удаляются автоматически."; $SUDO rm -f "$TELEMT_STATE"; $SUDO systemctl daemon-reload; ok "Интеграция удалена."
}

case "${1:-status}" in install) telemt_install ;; status) telemt_status ;; remove|uninstall) telemt_remove ;; *) die "telemt-manager: install|status|remove" ;; esac
