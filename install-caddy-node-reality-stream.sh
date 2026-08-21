#!/usr/bin/env bash
set -Eeo pipefail

REPO_RAW="https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/main"
INSTALL_DIR=/opt/remna-node-scripts
SELF="$INSTALL_DIR/install-caddy-node-reality-stream.sh"
CORE="$INSTALL_DIR/install-caddy-node-reality-stream-core.sh"
TELEMT_HELPER="$INSTALL_DIR/telemt-manager.sh"
CADDYFILE=/etc/caddy/Caddyfile
CADDY_PUBLIC=/etc/caddy/Caddyfile.public
PANEL_CONFIG=/etc/telemt-panel/config.toml
STREAM_SOURCES=(
  "https://rustream.remna.space"
  "https://est.remna.2rdp.ru"
  "https://nl.remna.2rdp.ru"
)

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
TTY=/dev/tty; { [ -r "$TTY" ] && [ -w "$TTY" ]; } || TTY=/dev/stdin
say(){ printf '%s\n' "$*"; }
ok(){ printf '✓ %s\n' "$*"; }
warn(){ printf '! %s\n' "$*" >&2; }
die(){ printf '✗ %s\n' "$*" >&2; exit 1; }

ensure_self(){
  local current; current="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  [ "$current" = "$SELF" ] && return 0
  $SUDO install -d -m 0755 "$INSTALL_DIR"
  $SUDO install -m 0700 "$current" "$SELF"
}

download_checked(){
  local url="$1" dst="$2" tmp; tmp="$(mktemp)"
  if curl -fsSL --connect-timeout 8 --max-time 30 "$url" -o "$tmp" && bash -n "$tmp"; then
    $SUDO install -m 0700 "$tmp" "$dst"; rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"; return 1
}

ensure_core(){
  $SUDO install -d -m 0755 "$INSTALL_DIR"
  if download_checked "$REPO_RAW/install-caddy-node-reality-stream-core.sh" "$CORE"; then
    return 0
  fi
  [ -s "$CORE" ] && bash -n "$CORE" && { warn "GitHub недоступен — использую проверенный локальный core."; return 0; }
  die "Не удалось получить рабочий core-скрипт."
}

ensure_telemt_helper(){
  if download_checked "$REPO_RAW/telemt-manager.sh" "$TELEMT_HELPER"; then return 0; fi
  [ -s "$TELEMT_HELPER" ] && bash -n "$TELEMT_HELPER" && { warn "GitHub недоступен — использую локальный Telemt helper."; return 0; }
  die "Не удалось получить Telemt helper."
}

choose_stream_source(){
  local src tmp; [ -n "${STREAM_SITE_URL:-}" ] && { printf '%s\n' "$STREAM_SITE_URL"; return 0; }
  tmp="$(mktemp)"
  for src in "${STREAM_SOURCES[@]}"; do
    if curl -kfsSL --connect-timeout 5 --max-time 15 --range 0-131071 "$src/" -o "$tmp" 2>/dev/null && grep -Eqi '<html|<!doctype|<head|<body' "$tmp"; then
      rm -f "$tmp"; printf '%s\n' "$src"; return 0
    fi
  done
  rm -f "$tmp"; return 1
}

prepare_stream_source(){
  local chosen
  chosen="$(choose_stream_source)" || die "Все источники стрим-сайта недоступны: ${STREAM_SOURCES[*]}. Существующий сайт не трогаю."
  export STREAM_SITE_URL="$chosen"
  ok "Источник стрим-сайта: $STREAM_SITE_URL"
}

ensure_net_admin(){
  local compose=/opt/remnanode/docker-compose.yml tmp
  [ -f "$compose" ] || return 0
  if grep -qE '^[[:space:]]*-[[:space:]]*NET_ADMIN[[:space:]]*$' "$compose"; then return 0; fi
  tmp="$(mktemp)"
  awk '
    {print}
    /^[[:space:]]*network_mode:[[:space:]]*host[[:space:]]*$/ {
      match($0,/^[[:space:]]*/); i=substr($0,1,RLENGTH)
      print i "cap_add:"
      print i "  - NET_ADMIN"
    }
  ' "$compose" > "$tmp"
  $SUDO cp -a "$compose" "${compose}.bak.$(date +%Y%m%d-%H%M%S)"
  $SUDO install -o root -g root -m 0600 "$tmp" "$compose"; rm -f "$tmp"
  ( cd /opt/remnanode && $SUDO docker compose config >/dev/null ) || die "NET_ADMIN не добавлен: docker compose config не прошёл проверку."
  ( cd /opt/remnanode && $SUDO docker compose up -d --force-recreate remnanode ) || die "Не удалось пересоздать remnanode с NET_ADMIN."
  sleep 3
  $SUDO docker inspect remnanode --format '{{json .HostConfig.CapAdd}}' 2>/dev/null | grep -q 'NET_ADMIN' || die "NET_ADMIN не применился к контейнеру."
  ok "Remnanode: CAP_NET_ADMIN включён."
}

rw_core_on_443(){ ss -lntp 2>/dev/null | grep -E ':443[[:space:]]' | grep -q 'rw-core'; }
caddy_local_8443(){ ss -lntp 2>/dev/null | grep -E '127\.0\.0\.1:8443[[:space:]]' | grep -q 'caddy'; }
caddy_public_443(){ ss -lntp 2>/dev/null | grep -E ':443[[:space:]]' | grep -q 'caddy'; }

restore_public_caddy_if_needed(){
  rw_core_on_443 && return 0
  caddy_local_8443 || return 0
  [ -s "$CADDY_PUBLIC" ] || { warn "REALITY не поднялся, но $CADDY_PUBLIC отсутствует — автоматический откат невозможен."; return 1; }
  $SUDO caddy validate --config "$CADDY_PUBLIC" --adapter caddyfile >/dev/null || { warn "Публичный Caddyfile невалиден — откат отменён."; return 1; }
  $SUDO cp -a "$CADDYFILE" "${CADDYFILE}.failed-reality.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  $SUDO install -o root -g root -m 0644 "$CADDY_PUBLIC" "$CADDYFILE"
  $SUDO systemctl restart caddy
  sleep 1
  caddy_public_443 || die "Не удалось вернуть Caddy на внешний 443."
  warn "REALITY/Xray не запущен — Caddy автоматически возвращён на :443, сайт сохранён."
}

ensure_telemt_route(){
  [ -f "$PANEL_CONFIG" ] || return 0
  [ -f "$CADDYFILE" ] || return 0
  grep -q 'handle /telemt\*' "$CADDYFILE" && return 0
  local tmp; tmp="$(mktemp)"
  awk 'BEGIN{i=0} /^[[:space:]]*handle[[:space:]]*\{[[:space:]]*$/ && !i {print "\thandle /telemt* {"; print "\t\treverse_proxy 127.0.0.1:8080"; print "\t}"; print ""; i=1} {print}' "$CADDYFILE" > "$tmp"
  if $SUDO caddy validate --config "$tmp" --adapter caddyfile >/dev/null; then
    $SUDO install -o root -g root -m 0644 "$tmp" "$CADDYFILE"; $SUDO systemctl reload caddy >/dev/null 2>&1 || $SUDO systemctl restart caddy >/dev/null 2>&1 || true
  else warn "Не удалось безопасно восстановить /telemt в Caddy."; fi
  rm -f "$tmp"
}

runtime_diagnose(){
  echo
  echo '────────────────────────────────────────────────────────────'
  echo '  [E] Runtime Remnanode/Xray'
  echo '────────────────────────────────────────────────────────────'
  if ! $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then say '  ✗ remnanode не запущен'; return 0; fi
  local xs cfgcount caps
  xs="$($SUDO docker exec remnanode /command/s6-svstat /run/service/xray 2>/dev/null || true)"
  cfgcount="$($SUDO docker exec remnanode sh -c 'find /run /tmp /var/lib /opt -maxdepth 4 -type f \( -iname "*xray*.json" -o -name config.json \) 2>/dev/null | wc -l' 2>/dev/null || echo '?')"
  caps="$($SUDO docker inspect remnanode --format '{{json .HostConfig.CapAdd}}' 2>/dev/null || true)"
  printf '  Node API : '; ss -ltnp 2>/dev/null | grep -q ':2222 ' && echo '✓ :2222 слушает' || echo '✗ :2222 не слушает'
  printf '  NET_ADMIN: '; printf '%s' "$caps" | grep -q NET_ADMIN && echo '✓ есть' || echo '✗ нет'
  printf '  Xray     : %s\n' "${xs:-неизвестно}"
  printf '  configs  : %s runtime-файл(ов)\n' "$cfgcount"
  if printf '%s' "$xs" | grep -q 'down (not started yet)' && [ "$cfgcount" = 0 ]; then
    echo '  ДИАГНОЗ  : Node работает, но Xray ещё не запускался и runtime-конфиг не получен.'
    echo '              Это НЕ ошибка Caddy и НЕ локальный firewall 2222.'
  fi
  if caddy_local_8443 && ! rw_core_on_443; then echo '  ! Caddy локальный :8443, а rw-core:443 отсутствует — сайт будет недоступен; нужен откат.'; fi
}

run_core(){
  local cmd="${1:-menu}"; ensure_core
  case "$cmd" in install|--auto|auto|front-only|front|reinstall|stream|site|decoy|set-decoy) prepare_stream_source ;; esac
  bash <(cat "$CORE") "$@"
  case "$cmd" in install|--auto|auto|reinstall|repair|fix) ensure_net_admin ;; esac
  restore_public_caddy_if_needed || true
  ensure_telemt_route || true
  case "$cmd" in diagnose|diag) runtime_diagnose ;; esac
}

telemt(){ ensure_telemt_helper; "$TELEMT_HELPER" "$@"; }

menu(){
  while true; do
    cat <<'MENU'

────────────────────────────────────────────────────────────
Remna Node Manager — safe mode
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
    printf 'Выбор: '; local c p; read -r c <"$TTY" || true
    case "$c" in
      1) run_core install ;; 2) run_core reinstall ;; 3) run_core front-only ;; 4) run_core path ;;
      5) printf 'Новый XHTTP-путь: '; read -r p <"$TTY" || true; [ -n "$p" ] && run_core path-set "$p" ;;
      6) run_core stream ;; 7) run_core summary ;; 8) run_core diagnose || true ;; 9) run_core status ;;
      10) run_core reality-prepare ;; 11) run_core reality-enable ;; 12) run_core reality-disable ;; 13) run_core reality-info ;;
      14) run_core repair ;; 15) telemt install ;; 16) telemt status ;; 17) telemt remove ;; 18) run_core clean ;;
      0|'') exit 0 ;; *) warn "Неизвестный пункт: $c" ;;
    esac
    printf '\nEnter — вернуться в меню... '; read -r _ <"$TTY" || true
  done
}

main(){
  ensure_self || true
  case "${1:-menu}" in
    menu|'') menu ;;
    telemt-install) telemt install ;; telemt-status) telemt status ;; telemt-remove|telemt-uninstall) telemt remove ;;
    *) run_core "$@" ;;
  esac
}
main "$@"
