#!/usr/bin/env bash
set -uo pipefail

SCRIPT_NAME="install-caddy-node-reality-stream.sh"
LOCAL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
BACKEND="${REMNA_BACKEND:-$LOCAL_DIR/$SCRIPT_NAME}"
[ -f "$BACKEND" ] || BACKEND="/opt/remna-node-scripts/$SCRIPT_NAME"

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
TTY=/dev/tty
{ [ -r "$TTY" ] && [ -w "$TTY" ]; } || TTY=/dev/stdin

if [ -t 1 ]; then
  N=$'\e[0m'; B=$'\e[1m'; DIM=$'\e[2m'
  R=$'\e[91m'; G=$'\e[92m'; Y=$'\e[93m'; C=$'\e[96m'
else
  N=""; B=""; DIM=""; R=""; G=""; Y=""; C=""
fi

say()  { printf '%b\n' "$*"; }
ok()   { printf '%b✓%b %s\n' "$G" "$N" "$*"; }
warn() { printf '%b!%b %s\n' "$Y" "$N" "$*"; }
err()  { printf '%b✗%b %s\n' "$R" "$N" "$*" >&2; }
line() { printf '%b────────────────────────────────────────────────────────────%b\n' "$DIM" "$N"; }

pause_menu() {
  printf '\nНажмите Enter, чтобы вернуться в меню... '
  read -r _ <"$TTY" || true
}

need_backend() {
  if [ -s "$BACKEND" ]; then return 0; fi
  err "Не найден основной скрипт: $BACKEND"
  say "Скачайте его рядом с менеджером или установите в /opt/remna-node-scripts/."
  return 1
}

run_backend() {
  need_backend || return 1
  # Отдельный процесс не даёт set/trap основного скрипта ломать цикл меню.
  bash "$BACKEND" "$@"
}

confirm() {
  local prompt="${1:-Продолжить?}" answer
  printf '%s [y/N] ' "$prompt"
  read -r answer <"$TTY" || true
  case "$answer" in [Yy]|[Yy][Ee][Ss]) return 0 ;; *) return 1 ;; esac
}

confirm_delete() {
  local answer
  say "${R}${B}ВНИМАНИЕ: операция необратима.${N}"
  printf 'Для подтверждения введите DELETE: '
  read -r answer <"$TTY" || true
  [ "$answer" = "DELETE" ]
}

remove_node_only() {
  say "${B}Удаление только Remnanode и локальных REALITY-файлов${N}"
  confirm "Удалить контейнер remnanode и /opt/remnanode?" || { warn "Отменено."; return 0; }
  if command -v docker >/dev/null 2>&1; then
    if [ -f /opt/remnanode/docker-compose.yml ]; then
      ( cd /opt/remnanode && $SUDO docker compose down ) >/dev/null 2>&1 || true
    fi
    $SUDO docker rm -f remnanode >/dev/null 2>&1 || true
  fi
  $SUDO rm -rf /opt/remnanode
  ok "Remnanode и /opt/remnanode удалены."
  warn "Запись ноды и Config Profile в панели Remnawave не удаляются автоматически."
}

remove_front_only() {
  local backup_dir="/root/remna-caddy-backup-$(date +%Y%m%d-%H%M%S)" f
  say "${B}Удаление Caddy-конфигурации и стрим-сайта${N}"
  confirm "Остановить Caddy и удалить локальные конфиги/сайт?" || { warn "Отменено."; return 0; }
  $SUDO install -d -m 0700 "$backup_dir"
  for f in /etc/caddy/Caddyfile /etc/caddy/Caddyfile.public /etc/caddy/Caddyfile.reality; do
    [ -f "$f" ] && $SUDO cp -a "$f" "$backup_dir/"
  done
  $SUDO systemctl stop caddy >/dev/null 2>&1 || true
  $SUDO rm -f /etc/caddy/Caddyfile /etc/caddy/Caddyfile.public /etc/caddy/Caddyfile.reality
  $SUDO rm -rf /var/www/mstream
  ok "Caddy-конфиги и стрим-сайт удалены."
  say "Бэкап конфигов: ${C}${backup_dir}${N}"
  warn "Сам пакет Caddy оставлен установленным."
}

remove_everything() {
  say "${B}Полное локальное удаление${N}"
  say "Будут удалены Remnanode, конфиги/сайт Caddy, пакет Caddy и /opt/remna-node-scripts."
  say "Firewall и объекты в панели Remnawave не изменяются."
  confirm_delete || { warn "Подтверждение не получено. Отменено."; return 0; }
  if [ -s "$BACKEND" ]; then
    bash "$BACKEND" clean || warn "Штатный clean завершился с ошибкой; продолжаю локальную очистку."
  else
    remove_node_only || true
    remove_front_only || true
  fi
  $SUDO systemctl disable --now caddy >/dev/null 2>&1 || true
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get purge -y caddy >/dev/null 2>&1 || true
    $SUDO apt-get autoremove -y >/dev/null 2>&1 || true
  fi
  $SUDO rm -f /etc/apt/sources.list.d/caddy-stable.list
  $SUDO rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  $SUDO rm -rf /etc/caddy /var/lib/caddy /var/log/caddy /var/www/mstream /opt/remnanode
  $SUDO rm -rf /opt/remna-node-scripts
  ok "Локальные компоненты удалены."
  warn "Если нода ещё есть в панели Remnawave — удалите её там вручную."
}

delete_menu() {
  while true; do
    printf '\n'; line; say "${B}${R}Удаление${N}"; line
    say "  [1] Удалить только Remnanode"
    say "  [2] Удалить только Caddy-конфиг и стрим-сайт"
    say "  [3] Штатный clean основного скрипта"
    say "  [4] Полное локальное удаление + пакет Caddy"
    say "  [0] Назад"
    printf '\nВыбор: '
    local choice
    read -r choice <"$TTY" || true
    case "$choice" in
      1) remove_node_only; pause_menu ;;
      2) remove_front_only; pause_menu ;;
      3) if confirm "Запустить штатный clean?"; then run_backend clean || true; else warn "Отменено."; fi; pause_menu ;;
      4) remove_everything; pause_menu ;;
      0|"") return 0 ;;
      *) warn "Неизвестный пункт: $choice" ;;
    esac
  done
}

show_menu() {
  printf '\n'; line
  say "${B}${C}Remna Node Manager${N}"
  say "${DIM}Caddy + XHTTP/CDN + REALITY + Remnanode${N}"
  line
  say "  [1]  Полная установка"
  say "  [2]  Переустановка с нуля"
  say "  [3]  Только фронт Caddy"
  say "  [4]  Сгенерировать XHTTP-путь"
  say "  [5]  Изменить XHTTP-путь"
  say "  [6]  Обновить стрим-сайт"
  say "  [7]  Сводка настроек"
  say "  [8]  Диагностика"
  say "  [9]  Статус сервисов"
  say "  [10] Подготовить REALITY"
  say "  [11] Включить REALITY"
  say "  [12] Отключить REALITY"
  say "  [13] Показать файлы REALITY"
  say "  [14] Repair текущей ноды"
  say "  [15] ${R}Удаление${N}"
  say "  [0]  Выход"
  line
  say "Backend: ${DIM}${BACKEND}${N}"
}

main() {
  while true; do
    show_menu
    printf '\nВыбор: '
    local choice path
    read -r choice <"$TTY" || true
    printf '\n'
    case "$choice" in
      1) run_backend install || true; pause_menu ;;
      2) run_backend reinstall || true; pause_menu ;;
      3) run_backend front-only || true; pause_menu ;;
      4) run_backend path || true; pause_menu ;;
      5) printf 'Новый XHTTP-путь (например /api/v3/data.php): '; read -r path <"$TTY" || true; [ -n "$path" ] && run_backend path-set "$path" || warn "Путь не задан."; pause_menu ;;
      6) run_backend stream || true; pause_menu ;;
      7) run_backend summary || true; pause_menu ;;
      8) run_backend diagnose || true; pause_menu ;;
      9) run_backend status || true; pause_menu ;;
      10) run_backend reality-prepare || true; pause_menu ;;
      11) run_backend reality-enable || true; pause_menu ;;
      12) run_backend reality-disable || true; pause_menu ;;
      13) run_backend reality-info || true; pause_menu ;;
      14) run_backend repair || true; pause_menu ;;
      15) delete_menu ;;
      0|"") exit 0 ;;
      *) warn "Неизвестный пункт: $choice"; pause_menu ;;
    esac
  done
}

main "$@"
