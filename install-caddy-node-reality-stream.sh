#!/usr/bin/env bash
set -Eeo pipefail

REPO_RAW="https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/main"
INSTALL_DIR=/opt/remna-node-scripts
CORE="$INSTALL_DIR/install-caddy-node-reality-stream-core.sh"
SELF="$INSTALL_DIR/install-caddy-node-reality-stream.sh"
TELEMT_INSTALL_URL="https://raw.githubusercontent.com/telemt/telemt/main/install.sh"
PANEL_INSTALL_URL="https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh"
PANEL_CONFIG=/etc/telemt-panel/config.toml
PANEL_PORT=18443
PANEL_LOCAL=127.0.0.1:8080
PANEL_PATH=/telemt
TELEMT_PORT_DEFAULT=5222
TELEMT_TLS_DEFAULT=www.apple.com

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
TTY=/dev/tty; { [ -r "$TTY" ] && [ -w "$TTY" ]; } || TTY=/dev/stdin
say(){ printf '%s\n' "$*"; }; ok(){ printf '✓ %s\n' "$*"; }; warn(){ printf '! %s\n' "$*" >&2; }; die(){ printf '✗ %s\n' "$*" >&2; exit 1; }

ensure_self(){ local current; current="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"; [ "$current" = "$SELF" ] && return 0; $SUDO install -d -m 0755 "$INSTALL_DIR"; $SUDO install -m 0700 "$current" "$SELF"; }
ensure_core(){ [ -s "$CORE" ] && return 0; command -v curl >/dev/null 2>&1 || die "Нужен curl."; $SUDO install -d -m 0755 "$INSTALL_DIR"; local tmp; tmp="$(mktemp)"; curl -fsSL "$REPO_RAW/install-caddy-node-reality-stream-core.sh" -o "$tmp" || { rm -f "$tmp"; die "Не удалось скачать core-скрипт."; }; bash -n "$tmp" || { rm -f "$tmp"; die "Скачанный core-скрипт повреждён."; }; $SUDO install -m 0700 "$tmp" "$CORE"; rm -f "$tmp"; }

panel_domain(){ local d="${DOMAIN:-}"; if [ -z "$d" ] && [ -f /etc/caddy/Caddyfile ]; then d="$(awk '/^[A-Za-z0-9.-]+[[:space:]]*\{/{gsub(/[[:space:]]*\{.*/,"",$0); print $1; exit}' /etc/caddy/Caddyfile 2>/dev/null || true)"; fi; printf '%s' "$d"; }
patch_caddy_file(){ local f="$1" tmp; [ -f "$f" ] || return 0; grep -q 'handle /telemt\*' "$f" && return 0; tmp="$(mktemp)"; awk 'BEGIN{inserted=0} /^[[:space:]]*handle[[:space:]]*\{[[:space:]]*$/ && !inserted {print "\thandle /telemt* {"; print "\t\treverse_proxy 127.0.0.1:8080"; print "\t}"; print ""; inserted=1} {print}' "$f" > "$tmp"; $SUDO install -o root -g root -m 0644 "$tmp" "$f"; rm -f "$tmp"; }
ensure_panel_caddy(){ [ -f "$PANEL_CONFIG" ] || return 0; command -v caddy >/dev/null 2>&1 || return 0; local f; for f in /etc/caddy/Caddyfile /etc/caddy/Caddyfile.public /etc/caddy/Caddyfile.reality; do patch_caddy_file "$f"; done; $SUDO caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null || die "После добавления /telemt Caddyfile невалиден."; $SUDO systemctl reload caddy >/dev/null 2>&1 || $SUDO systemctl restart caddy >/dev/null 2>&1 || true; }
configure_panel_file(){ [ -f "$PANEL_CONFIG" ] || die "Не найден $PANEL_CONFIG после установки панели."; local tmp; tmp="$(mktemp)"; awk 'BEGIN{have_base=0} /^listen[[:space:]]*=/ {print "listen = \"127.0.0.1:8080\""; next} /^base_path[[:space:]]*=/ {print "base_path = \"/telemt\""; have_base=1; next} /^# base_path[[:space:]]*=/ {print "base_path = \"/telemt\""; have_base=1; next} /^\[telemt\]$/ && !have_base {print "base_path = \"/telemt\"\n"; have_base=1} {print}' "$PANEL_CONFIG" > "$tmp"; $SUDO install -o telemt-panel -g telemt-panel -m 0600 "$tmp" "$PANEL_CONFIG"; rm -f "$tmp"; $SUDO systemctl restart telemt-panel; }

install_redirect_service(){ command -v iptables >/dev/null 2>&1 || { $SUDO apt-get update -y; $SUDO apt-get install -y iptables; }; cat <<UNIT | $SUDO tee /etc/systemd/system/telemt-panel-${PANEL_PORT}.service >/dev/null
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
$SUDO systemctl daemon-reload; $SUDO systemctl enable --now "telemt-panel-${PANEL_PORT}.service"; }
open_firewall_port(){ local p="$1"; if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -qi 'Status: active'; then $SUDO ufw allow "${p}/tcp" >/dev/null; fi; }

cmd_telemt_install(){ local port tlsdomain pdomain tmp; printf 'Внешний порт Telemt [%s]: ' "$TELEMT_PORT_DEFAULT"; read -r port <"$TTY" || true; port="${port:-$TELEMT_PORT_DEFAULT}"; printf 'Fake-TLS домен Telemt [%s]: ' "$TELEMT_TLS_DEFAULT"; read -r tlsdomain <"$TTY" || true; tlsdomain="${tlsdomain:-$TELEMT_TLS_DEFAULT}"; printf '%s' "$port" | grep -Eq '^[0-9]+$' || die "Порт должен быть числом."; [ "$port" -ne 443 ] || die "TCP/443 зарезервирован для REALITY/Caddy."; if ss -ltn 2>/dev/null | grep -Eq ":${port}[[:space:]]"; then die "TCP/$port уже занят."; fi; tmp="$(mktemp)"; curl -fsSL "$TELEMT_INSTALL_URL" -o "$tmp" || die "Не удалось скачать installer Telemt."; $SUDO sh "$tmp" -l ru -d "$tlsdomain" -p "$port"; rm -f "$tmp"; open_firewall_port "$port"; tmp="$(mktemp)"; curl -fsSL "$PANEL_INSTALL_URL" -o "$tmp" || die "Не удалось скачать installer Telemt Panel."; say "Официальный installer панели запросит логин и пароль."; $SUDO bash "$tmp"; rm -f "$tmp"; configure_panel_file; ensure_panel_caddy; install_redirect_service; open_firewall_port "$PANEL_PORT"; pdomain="$(panel_domain)"; ok "Telemt и Telemt Panel установлены."; say "Telemt: TCP/$port"; say "Panel local: http://$PANEL_LOCAL$PANEL_PATH/login"; [ -z "$pdomain" ] || say "Panel HTTPS: https://${pdomain}:${PANEL_PORT}${PANEL_PATH}/login"; warn "TCP/443 остаётся за REALITY/Caddy."; }
cmd_telemt_status(){ local pdomain; say "Telemt:"; $SUDO systemctl --no-pager --full status telemt 2>/dev/null | sed -n '1,8p' || true; say ""; say "Telemt Panel:"; $SUDO systemctl --no-pager --full status telemt-panel 2>/dev/null | sed -n '1,8p' || true; say ""; say "Порты:"; ss -ltnp 2>/dev/null | grep -E ':5222 |:5223 |:8530 |:8080 |:9091 |:18443 |:443 ' || true; say ""; say "Redirect ${PANEL_PORT}->443:"; $SUDO iptables -t nat -S PREROUTING 2>/dev/null | grep -- "--dport ${PANEL_PORT}" || echo "нет"; pdomain="$(panel_domain)"; [ -z "$pdomain" ] || say "URL: https://${pdomain}:${PANEL_PORT}${PANEL_PATH}/login"; }
cmd_telemt_remove(){ local yn tmp; printf 'Удалить Telemt + Telemt Panel? [y/N] '; read -r yn <"$TTY" || true; case "$yn" in [Yy]*) : ;; *) warn "Отменено."; return 0 ;; esac; $SUDO systemctl disable --now "telemt-panel-${PANEL_PORT}.service" >/dev/null 2>&1 || true; $SUDO rm -f "/etc/systemd/system/telemt-panel-${PANEL_PORT}.service"; $SUDO iptables -t nat -D PREROUTING -p tcp --dport "$PANEL_PORT" -j REDIRECT --to-ports 443 2>/dev/null || true; tmp="$(mktemp)"; if curl -fsSL "$PANEL_INSTALL_URL" -o "$tmp"; then $SUDO bash "$tmp" purge || true; fi; rm -f "$tmp"; tmp="$(mktemp)"; if curl -fsSL "$TELEMT_INSTALL_URL" -o "$tmp"; then $SUDO sh "$tmp" purge || true; fi; rm -f "$tmp"; $SUDO systemctl daemon-reload; ok "Telemt и Telemt Panel удалены. Caddy/Remnanode не тронуты."; }

run_core(){ ensure_core; "$CORE" "$@"; [ ! -f "$PANEL_CONFIG" ] || ensure_panel_caddy; }
menu(){ while true; do cat <<'MENU'

────────────────────────────────────────────────────────────
Remna Node — Caddy + XHTTP + REALITY + Telemt
────────────────────────────────────────────────────────────
 [1]  Полная установка
 [2]  Переустановка с нуля
 [3]  Только фронт Caddy
 [4]  Сгенерировать XHTTP-путь
 [5]  Изменить XHTTP-путь
 [6]  Обновить стрим-сайт
 [7]  Сводка настроек
 [8]  Диагностика
 [9]  Статус сервисов
 [10] Подготовить REALITY
 [11] Включить REALITY
 [12] Отключить REALITY
 [13] Файлы REALITY
 [14] Repair текущей ноды
 [15] Установить/настроить Telemt + Panel
 [16] Статус Telemt + Panel
 [17] Удалить Telemt + Panel
 [18] Clean Remnanode/Caddy
 [0]  Выход
────────────────────────────────────────────────────────────
MENU
printf 'Выбор: '; local c p; read -r c <"$TTY" || true; case "$c" in 1) run_core install ;; 2) run_core reinstall ;; 3) run_core front-only ;; 4) run_core path ;; 5) printf 'Новый XHTTP-путь: '; read -r p <"$TTY" || true; [ -n "$p" ] && run_core path-set "$p" ;; 6) run_core stream ;; 7) run_core summary ;; 8) run_core diagnose || true ;; 9) run_core status ;; 10) run_core reality-prepare ;; 11) run_core reality-enable ;; 12) run_core reality-disable ;; 13) run_core reality-info ;; 14) run_core repair ;; 15) cmd_telemt_install ;; 16) cmd_telemt_status ;; 17) cmd_telemt_remove ;; 18) run_core clean ;; 0|"") exit 0 ;; *) warn "Неизвестный пункт: $c" ;; esac; printf '\nEnter — вернуться в меню... '; read -r _ <"$TTY" || true; done; }
main(){ ensure_self || true; case "${1:-menu}" in menu|"") menu ;; telemt-install) cmd_telemt_install ;; telemt-status) cmd_telemt_status ;; telemt-remove|telemt-uninstall) cmd_telemt_remove ;; *) run_core "$@" ;; esac; }
main "$@"
