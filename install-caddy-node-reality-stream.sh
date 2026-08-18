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
STATE_DIR=/var/lib/remna-node-scripts
TELEMT_STATE="$STATE_DIR/telemt-integration.env"
CADDY_MARK_BEGIN="# BEGIN REMNA TELEMT PANEL"
CADDY_MARK_END="# END REMNA TELEMT PANEL"

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
TTY=/dev/tty; { [ -r "$TTY" ] && [ -w "$TTY" ]; } || TTY=/dev/stdin
say(){ printf '%s\n' "$*"; }; ok(){ printf '✓ %s\n' "$*"; }; warn(){ printf '! %s\n' "$*" >&2; }; die(){ printf '✗ %s\n' "$*" >&2; exit 1; }

ensure_self(){ local current; current="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"; [ "$current" = "$SELF" ] && return 0; $SUDO install -d -m 0755 "$INSTALL_DIR"; $SUDO install -m 0700 "$current" "$SELF"; }
ensure_core(){ [ -s "$CORE" ] && return 0; command -v curl >/dev/null 2>&1 || die "Нужен curl."; $SUDO install -d -m 0755 "$INSTALL_DIR"; local tmp; tmp="$(mktemp)"; curl -fsSL "$REPO_RAW/install-caddy-node-reality-stream-core.sh" -o "$tmp" || { rm -f "$tmp"; die "Не удалось скачать core-скрипт."; }; bash -n "$tmp" || { rm -f "$tmp"; die "Скачанный core-скрипт повреждён."; }; $SUDO install -m 0700 "$tmp" "$CORE"; rm -f "$tmp"; }

panel_domain(){ local d="${DOMAIN:-}"; if [ -z "$d" ] && [ -f /etc/caddy/Caddyfile ]; then d="$(awk '/^[A-Za-z0-9.-]+[[:space:]]*\{/{gsub(/[[:space:]]*\{.*/,"",$0); print $1; exit}' /etc/caddy/Caddyfile 2>/dev/null || true)"; fi; printf '%s' "$d"; }

list_telemt_units(){ systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '$1 ~ /^telemt[0-9]*\.service$/ {print $1}' | sort -V; }
choose_existing_telemt(){
  local unit api config
  if systemctl list-unit-files telemt1.service >/dev/null 2>&1 && systemctl cat telemt1.service >/dev/null 2>&1; then
    unit=telemt1.service; api=9091; config=/etc/telemt/telemt1.toml
  elif systemctl list-unit-files telemt.service >/dev/null 2>&1 && systemctl cat telemt.service >/dev/null 2>&1; then
    unit=telemt.service; api=9091; config=/etc/telemt/telemt.toml
  else
    unit=""; api=""; config=""
  fi
  printf '%s|%s|%s\n' "$unit" "$api" "$config"
}

save_state(){
  local managed_telemt="$1" managed_panel="$2" unit="$3" api="$4" config="$5"
  $SUDO install -d -o root -g root -m 0700 "$STATE_DIR"
  local tmp; tmp="$(mktemp)"
  cat >"$tmp" <<STATE
MANAGED_TELEMT=$managed_telemt
MANAGED_PANEL=$managed_panel
TELEMT_UNIT=$unit
TELEMT_API_PORT=$api
TELEMT_CONFIG=$config
STATE
  $SUDO install -o root -g root -m 0600 "$tmp" "$TELEMT_STATE"
  rm -f "$tmp"
}
load_state(){ MANAGED_TELEMT=0; MANAGED_PANEL=0; TELEMT_UNIT=""; TELEMT_API_PORT=""; TELEMT_CONFIG=""; [ -s "$TELEMT_STATE" ] && . "$TELEMT_STATE"; }

render_caddy_with_panel(){
  local src="$1" dst="$2"
  awk -v begin="$CADDY_MARK_BEGIN" -v end="$CADDY_MARK_END" '
    BEGIN{skip=0; inserted=0}
    $0==begin {skip=1; next}
    $0==end {skip=0; next}
    skip {next}
    /^[[:space:]]*handle[[:space:]]*\{[[:space:]]*$/ && !inserted {
      print "\t" begin
      print "\thandle /telemt* {"
      print "\t\treverse_proxy 127.0.0.1:8080"
      print "\t}"
      print "\t" end
      print ""
      inserted=1
    }
    {print}
    END{if(!inserted) exit 42}
  ' "$src" > "$dst"
}

patch_caddy_file(){
  local f="$1" tmp backup
  [ -f "$f" ] || return 0
  tmp="$(mktemp)"; backup="${f}.telemt-backup.$(date +%Y%m%d-%H%M%S)"
  render_caddy_with_panel "$f" "$tmp" || { rm -f "$tmp"; die "Не найден безопасный handle{} для вставки Telemt в $f"; }
  $SUDO caddy validate --config "$tmp" --adapter caddyfile >/dev/null || { rm -f "$tmp"; die "Telemt-маршрут сделал $f невалидным; исходный файл не изменён."; }
  $SUDO cp -a "$f" "$backup"
  $SUDO install -o root -g root -m 0644 "$tmp" "$f"
  rm -f "$tmp"
}

remove_caddy_panel_block(){
  local f="$1" tmp
  [ -f "$f" ] || return 0
  grep -Fq "$CADDY_MARK_BEGIN" "$f" || return 0
  tmp="$(mktemp)"
  awk -v begin="$CADDY_MARK_BEGIN" -v end="$CADDY_MARK_END" 'BEGIN{skip=0} index($0,begin){skip=1;next} index($0,end){skip=0;next} !skip{print}' "$f" > "$tmp"
  $SUDO caddy validate --config "$tmp" --adapter caddyfile >/dev/null || { rm -f "$tmp"; warn "Не удалось безопасно убрать Telemt-блок из $f; файл оставлен как есть."; return 1; }
  $SUDO install -o root -g root -m 0644 "$tmp" "$f"; rm -f "$tmp"
}

ensure_panel_caddy(){
  [ -f "$PANEL_CONFIG" ] || return 0
  command -v caddy >/dev/null 2>&1 || die "Caddy не найден."
  local f
  for f in /etc/caddy/Caddyfile /etc/caddy/Caddyfile.public /etc/caddy/Caddyfile.reality; do patch_caddy_file "$f"; done
  $SUDO caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null || die "Caddyfile невалиден после безопасной вставки Telemt."
  $SUDO systemctl reload caddy >/dev/null 2>&1 || $SUDO systemctl restart caddy >/dev/null 2>&1 || true
}

configure_panel_file(){
  local unit="$1" api="$2" config="$3" tmp backup
  [ -f "$PANEL_CONFIG" ] || die "Не найден $PANEL_CONFIG после установки панели."
  backup="${PANEL_CONFIG}.backup.$(date +%Y%m%d-%H%M%S)"; $SUDO cp -a "$PANEL_CONFIG" "$backup"
  tmp="$(mktemp)"
  awk -v unit="$unit" -v api="$api" -v cfg="$config" '
    BEGIN{sec=""; have_base=0; have_service=0; have_cfg=0}
    /^\[[^]]+\]/{sec=$0}
    /^listen[[:space:]]*=/ {print "listen = \"127.0.0.1:8080\""; next}
    /^base_path[[:space:]]*=/ {print "base_path = \"/telemt\""; have_base=1; next}
    /^# base_path[[:space:]]*=/ {print "base_path = \"/telemt\""; have_base=1; next}
    /^\[telemt\]$/ {if(!have_base){print "base_path = \"/telemt\"\n"; have_base=1}; print; sec="[telemt]"; next}
    sec=="[telemt]" && /^url[[:space:]]*=/ {print "url = \"http://127.0.0.1:" api "\""; next}
    sec=="[telemt]" && /^service_name[[:space:]]*=/ {print "service_name = \"" unit "\""; have_service=1; next}
    sec=="[telemt]" && /^# service_name[[:space:]]*=/ {print "service_name = \"" unit "\""; have_service=1; next}
    sec=="[telemt]" && /^config_path[[:space:]]*=/ {print "config_path = \"" cfg "\""; have_cfg=1; next}
    sec=="[telemt]" && /^# config_path[[:space:]]*=/ {print "config_path = \"" cfg "\""; have_cfg=1; next}
    {print}
    END{}
  ' "$PANEL_CONFIG" > "$tmp"
  if ! grep -q '^service_name[[:space:]]*=' "$tmp"; then sed -i "/^\[telemt\]$/a service_name = \"$unit\"" "$tmp"; fi
  if ! grep -q '^config_path[[:space:]]*=' "$tmp"; then sed -i "/^\[telemt\]$/a config_path = \"$config\"" "$tmp"; fi
  $SUDO install -o telemt-panel -g telemt-panel -m 0600 "$tmp" "$PANEL_CONFIG"; rm -f "$tmp"
  $SUDO systemctl restart telemt-panel
  ok "Telemt Panel настроена на $unit API 127.0.0.1:$api; backup: $backup"
}

install_redirect_service(){
  command -v iptables >/dev/null 2>&1 || { $SUDO apt-get update -y; $SUDO apt-get install -y iptables; }
  if $SUDO iptables -t nat -S PREROUTING 2>/dev/null | grep -q -- "--dport ${PANEL_PORT} .*--to-ports 443"; then ok "Redirect ${PANEL_PORT}->443 уже существует."; else
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
  fi
}
open_firewall_port(){ local p="$1"; if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -qi 'Status: active'; then $SUDO ufw allow "${p}/tcp" >/dev/null; fi; }

cmd_telemt_install(){
  local detected unit api config managed_telemt=0 managed_panel=0 port tlsdomain tmp pdomain
  detected="$(choose_existing_telemt)"; IFS='|' read -r unit api config <<<"$detected"
  if [ -n "$unit" ]; then
    ok "Найден существующий $unit — НЕ обновляю и НЕ меняю его конфиг."
    say "Найденные Telemt units:"; list_telemt_units | sed 's/^/  - /'
  else
    printf 'Telemt не найден. Установить новый стандартный telemt.service? [y/N] '; read -r yn <"$TTY" || true
    case "$yn" in [Yy]*) : ;; *) warn "Telemt не установлен; Panel без Telemt API не настраиваю."; return 0 ;; esac
    printf 'Внешний порт Telemt [%s]: ' "$TELEMT_PORT_DEFAULT"; read -r port <"$TTY" || true; port="${port:-$TELEMT_PORT_DEFAULT}"
    printf 'Fake-TLS домен Telemt [%s]: ' "$TELEMT_TLS_DEFAULT"; read -r tlsdomain <"$TTY" || true; tlsdomain="${tlsdomain:-$TELEMT_TLS_DEFAULT}"
    printf '%s' "$port" | grep -Eq '^[0-9]+$' || die "Порт должен быть числом."; [ "$port" -ne 443 ] || die "TCP/443 зарезервирован для REALITY/Caddy."
    ss -ltn 2>/dev/null | grep -Eq ":${port}[[:space:]]" && die "TCP/$port уже занят."
    tmp="$(mktemp)"; curl -fsSL "$TELEMT_INSTALL_URL" -o "$tmp" || { rm -f "$tmp"; die "Не удалось скачать installer Telemt."; }
    $SUDO sh "$tmp" -l ru -d "$tlsdomain" -p "$port"; rm -f "$tmp"; open_firewall_port "$port"
    unit=telemt.service; api=9091; config=/etc/telemt/telemt.toml; managed_telemt=1
  fi

  if systemctl cat telemt-panel.service >/dev/null 2>&1 && [ -f "$PANEL_CONFIG" ]; then
    ok "Существующая Telemt Panel найдена — НЕ переустанавливаю, только делаю backup и безопасно настраиваю интеграцию."
  else
    tmp="$(mktemp)"; curl -fsSL "$PANEL_INSTALL_URL" -o "$tmp" || { rm -f "$tmp"; die "Не удалось скачать installer Telemt Panel."; }
    say "Официальный installer панели запросит логин и пароль."
    $SUDO bash "$tmp"; rm -f "$tmp"; managed_panel=1
  fi
  configure_panel_file "${unit%.service}" "$api" "$config"
  ensure_panel_caddy
  install_redirect_service
  open_firewall_port "$PANEL_PORT"
  save_state "$managed_telemt" "$managed_panel" "$unit" "$api" "$config"
  pdomain="$(panel_domain)"
  ok "Telemt-интеграция готова; существующие экземпляры не затронуты."
  say "Panel local: http://$PANEL_LOCAL$PANEL_PATH/login"
  [ -z "$pdomain" ] || say "Panel HTTPS: https://${pdomain}:${PANEL_PORT}${PANEL_PATH}/login"
}

cmd_telemt_status(){
  local pdomain; load_state
  say "Telemt units:"; list_telemt_units | while read -r u; do printf '  %-18s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done
  say "Telemt Panel: $(systemctl is-active telemt-panel 2>/dev/null || echo absent)"
  say "Порты:"; ss -ltnp 2>/dev/null | grep -E ':5222 |:5223 |:8530 |:8080 |:9091 |:9092 |:9093 |:18443 |:443 ' || true
  say "Redirect ${PANEL_PORT}->443:"; $SUDO iptables -t nat -S PREROUTING 2>/dev/null | grep -- "--dport ${PANEL_PORT}" || echo "  нет"
  pdomain="$(panel_domain)"; [ -z "$pdomain" ] || say "URL: https://${pdomain}:${PANEL_PORT}${PANEL_PATH}/login"
  [ -s "$TELEMT_STATE" ] && say "State: $TELEMT_STATE" || say "State: интеграция ещё не записана"
}

cmd_telemt_remove(){
  local yn tmp; load_state
  printf 'Убрать только интеграцию Telemt Panel (18443 + /telemt)? [y/N] '; read -r yn <"$TTY" || true
  case "$yn" in [Yy]*) : ;; *) warn "Отменено."; return 0 ;; esac
  $SUDO systemctl disable --now "telemt-panel-${PANEL_PORT}.service" >/dev/null 2>&1 || true
  $SUDO rm -f "/etc/systemd/system/telemt-panel-${PANEL_PORT}.service"
  $SUDO iptables -t nat -D PREROUTING -p tcp --dport "$PANEL_PORT" -j REDIRECT --to-ports 443 2>/dev/null || true
  local f; for f in /etc/caddy/Caddyfile /etc/caddy/Caddyfile.public /etc/caddy/Caddyfile.reality; do remove_caddy_panel_block "$f" || true; done
  $SUDO systemctl reload caddy >/dev/null 2>&1 || true
  if [ "$MANAGED_PANEL" = 1 ]; then
    printf 'Panel была установлена этим скриптом. Удалить её полностью? [y/N] '; read -r yn <"$TTY" || true
    if [[ "$yn" =~ ^[Yy]$ ]]; then tmp="$(mktemp)"; if curl -fsSL "$PANEL_INSTALL_URL" -o "$tmp"; then $SUDO bash "$tmp" purge || true; fi; rm -f "$tmp"; fi
  else
    warn "Существующая Telemt Panel НЕ удалена."
  fi
  if [ "$MANAGED_TELEMT" = 1 ]; then
    printf 'Telemt был установлен этим скриптом. Удалить только этот telemt.service? [y/N] '; read -r yn <"$TTY" || true
    if [[ "$yn" =~ ^[Yy]$ ]]; then tmp="$(mktemp)"; if curl -fsSL "$TELEMT_INSTALL_URL" -o "$tmp"; then $SUDO sh "$tmp" purge || true; fi; rm -f "$tmp"; fi
  else
    warn "Существующие telemt1/2/3/telemt НЕ удалялись и не изменялись."
  fi
  $SUDO rm -f "$TELEMT_STATE"; $SUDO systemctl daemon-reload
  ok "Интеграция Telemt Panel удалена безопасно."
}

run_core(){ ensure_core; bash <(cat "$CORE") "$@"; [ ! -f "$PANEL_CONFIG" ] || ensure_panel_caddy; }
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
 [15] Безопасно подключить Telemt + Panel
 [16] Статус Telemt + Panel
 [17] Убрать интеграцию Telemt Panel
 [18] Clean Remnanode/Caddy
 [0]  Выход
────────────────────────────────────────────────────────────
MENU
printf 'Выбор: '; local c p; read -r c <"$TTY" || true; case "$c" in 1) run_core install ;; 2) run_core reinstall ;; 3) run_core front-only ;; 4) run_core path ;; 5) printf 'Новый XHTTP-путь: '; read -r p <"$TTY" || true; [ -n "$p" ] && run_core path-set "$p" ;; 6) run_core stream ;; 7) run_core summary ;; 8) run_core diagnose || true ;; 9) run_core status ;; 10) run_core reality-prepare ;; 11) run_core reality-enable ;; 12) run_core reality-disable ;; 13) run_core reality-info ;; 14) run_core repair ;; 15) cmd_telemt_install ;; 16) cmd_telemt_status ;; 17) cmd_telemt_remove ;; 18) run_core clean ;; 0|"") exit 0 ;; *) warn "Неизвестный пункт: $c" ;; esac; printf '\nEnter — вернуться в меню... '; read -r _ <"$TTY" || true; done; }
main(){ ensure_self || true; case "${1:-menu}" in menu|"") menu ;; telemt-install) cmd_telemt_install ;; telemt-status) cmd_telemt_status ;; telemt-remove|telemt-uninstall) cmd_telemt_remove ;; *) run_core "$@" ;; esac; }
main "$@"
