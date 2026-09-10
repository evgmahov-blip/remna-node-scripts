#!/usr/bin/env bash
set -Eeuo pipefail

TASK_NAME="REMNA NODE FULL CLEAN"
INSTALL_DIR="/opt/remna-node-scripts"
NODE_DIR="/opt/remnanode"
PROTECTION_DIR="/opt/remna-protection"
PROTECTION_LOG="/var/log/remna-protection"
WEBROOT="/var/www/mstream"
CADDY_DIR="/etc/caddy"
CADDY_DROPIN="/etc/systemd/system/caddy.service.d/10-remna-topology-guard.conf"
PROTECTION_HELPER="$INSTALL_DIR/protection-manager.sh"
MANAGER_URL="https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/main/install-caddy-node-reality-stream.sh"
MANAGER_PATH="$INSTALL_DIR/install-caddy-node-reality-stream.sh"
BACKUP_ROOT="/root/remna-node-clean-backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/$STAMP"
MODE="${1:-menu}"
ASSUME_YES="${ASSUME_YES:-0}"

printf '#################### НАЧАЛО ВЫВОДА: %s ####################\n' "$TASK_NAME"

finish_marker() {
  local rc=$?
  printf '#################### КОНЕЦ ВЫВОДА: %s ####################\n' "$TASK_NAME"
  return "$rc"
}
trap finish_marker EXIT

say(){ printf '%s\n' "$*"; }
ok(){ printf '[OK] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }
die(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }

if [ "$(id -u)" -ne 0 ]; then
  die "Запусти скрипт от root: sudo bash $0"
  return 1 2>/dev/null || true
fi

TTY=/dev/tty
{ [ -r "$TTY" ] && [ -w "$TTY" ]; } || TTY=/dev/stdin

run_quiet(){ "$@" >/dev/null 2>&1 || true; }

ssh_service_name(){
  if systemctl list-unit-files ssh.service >/dev/null 2>&1; then printf 'ssh\n'; return; fi
  if systemctl list-unit-files sshd.service >/dev/null 2>&1; then printf 'sshd\n'; return; fi
  printf '\n'
}

ssh_listener_present(){
  ss -lntp 2>/dev/null | grep -qE 'LISTEN.+sshd' || ss -lntp 2>/dev/null | grep -qE ':(22|[0-9]{4,5})[[:space:]].*sshd'
}

preflight(){
  local sshsvc
  sshsvc="$(ssh_service_name)"
  [ -n "$sshsvc" ] || die "Не найден systemd unit SSH (ssh/sshd). Очистку не начинаю."
  systemctl is-active --quiet "$sshsvc" || die "SSH service $sshsvc не активен. Очистку не начинаю."
  ssh_listener_present || die "Не вижу слушающего sshd. Очистку не начинаю."
  ip route show default 2>/dev/null | grep -q '^default ' || die "Нет default route. Очистку не начинаю."
  command -v tar >/dev/null 2>&1 || die "tar не найден."
  command -v ss >/dev/null 2>&1 || die "ss не найден."
  ok "Precheck: SSH активен, sshd слушает, default route есть."
}

copy_if_exists(){
  local src="$1" rel
  [ -e "$src" ] || return 0
  rel="${src#/}"
  mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
  cp -a "$src" "$BACKUP_DIR/$rel" 2>/dev/null || warn "Не удалось скопировать $src в recovery bundle."
}

make_backup(){
  umask 077
  mkdir -p "$BACKUP_DIR/state"

  copy_if_exists "$NODE_DIR"
  copy_if_exists "$PROTECTION_DIR"
  copy_if_exists "$PROTECTION_LOG"
  copy_if_exists "$WEBROOT"
  copy_if_exists "$CADDY_DIR/Caddyfile"
  copy_if_exists "$CADDY_DIR/Caddyfile.public"
  copy_if_exists "$CADDY_DIR/Caddyfile.reality"
  copy_if_exists "$CADDY_DROPIN"
  copy_if_exists "/etc/hysteria"
  copy_if_exists "/etc/hysteria2"
  copy_if_exists "/etc/systemd/system/hysteria-server.service"
  copy_if_exists "/etc/systemd/system/hysteria2.service"
  copy_if_exists "/etc/systemd/system/remna-reality-handoff.service"
  copy_if_exists "/etc/systemd/system/remna-reality-handoff.timer"
  copy_if_exists "/etc/systemd/system/remna-profile-wait.service"
  copy_if_exists "/etc/systemd/system/remna-protection.service"
  copy_if_exists "/etc/systemd/system/remna-protection-update.service"
  copy_if_exists "/etc/systemd/system/remna-protection-update.timer"
  copy_if_exists "/etc/systemd/system/remnanode-rkn-scanner-boot.service"
  copy_if_exists "/etc/systemd/system/remnanode-rkn-scanner-update.service"
  copy_if_exists "/etc/systemd/system/remnanode-rkn-scanner-update.timer"

  systemctl list-unit-files --no-pager > "$BACKUP_DIR/state/systemd-unit-files.txt" 2>&1 || true
  systemctl --no-pager --all status ssh sshd caddy remna-protection remna-reality-handoff.timer remnanode-rkn-scanner-boot.service remnanode-rkn-scanner-update.timer > "$BACKUP_DIR/state/service-status.txt" 2>&1 || true
  ss -lntup > "$BACKUP_DIR/state/listening-ports.txt" 2>&1 || true
  ip addr show > "$BACKUP_DIR/state/ip-address.txt" 2>&1 || true
  ip route show table all > "$BACKUP_DIR/state/ip-routes.txt" 2>&1 || true
  ip rule show > "$BACKUP_DIR/state/ip-rules.txt" 2>&1 || true
  command -v docker >/dev/null 2>&1 && docker ps -a --no-trunc > "$BACKUP_DIR/state/docker-ps.txt" 2>&1 || true
  command -v docker >/dev/null 2>&1 && docker network ls > "$BACKUP_DIR/state/docker-networks.txt" 2>&1 || true
  command -v iptables-save >/dev/null 2>&1 && iptables-save > "$BACKUP_DIR/state/iptables-save.txt" 2>&1 || true
  command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > "$BACKUP_DIR/state/ip6tables-save.txt" 2>&1 || true
  command -v ipset >/dev/null 2>&1 && ipset save > "$BACKUP_DIR/state/ipset-save.txt" 2>&1 || true
  command -v ufw >/dev/null 2>&1 && ufw status numbered > "$BACKUP_DIR/state/ufw-status-numbered.txt" 2>&1 || true

  tar -C "$BACKUP_ROOT" -czf "$BACKUP_ROOT/remna-node-clean-$STAMP.tar.gz" "$STAMP" 2>/dev/null || warn "Не удалось создать tar.gz; каталог backup всё равно сохранён: $BACKUP_DIR"
  chmod -R go-rwx "$BACKUP_DIR" "$BACKUP_ROOT/remna-node-clean-$STAMP.tar.gz" 2>/dev/null || true
  ok "Recovery bundle: $BACKUP_DIR"
}

remove_unit(){
  local unit="$1" path="/etc/systemd/system/$1"
  run_quiet systemctl disable --now "$unit"
  rm -f "$path"
}

remove_matching_remna_units(){
  local unit
  for unit in \
    remna-profile-wait.service \
    remna-reality-handoff.service \
    remna-reality-handoff.timer \
    remna-protection.service \
    remna-protection-update.service \
    remna-protection-update.timer \
    remnanode-rkn-scanner-boot.service \
    remnanode-rkn-scanner-update.service \
    remnanode-rkn-scanner-update.timer \
    remnanode-rkn-watcher.service \
    remnanode-rkn-watcher.timer \
    remna-rkn-watcher.service \
    remna-rkn-watcher.timer; do
    remove_unit "$unit"
  done

  rm -f "$CADDY_DROPIN"
  rmdir /etc/systemd/system/caddy.service.d 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true
  ok "Старые Remna/RKN systemd units и Caddy topology drop-in удалены."
}

remove_protection_firewall(){
  local panel_ip=""
  if [ -f "$PROTECTION_DIR/settings.conf" ]; then
    panel_ip="$(awk -F= '$1=="PANEL_IP"{print $2; exit}' "$PROTECTION_DIR/settings.conf" 2>/dev/null || true)"
  fi

  if [ -x "$PROTECTION_HELPER" ]; then
    "$PROTECTION_HELPER" uninstall >/dev/null 2>&1 || warn "protection-manager uninstall завершился с ошибкой; применяю ручную адресную очистку."
  fi

  if command -v iptables >/dev/null 2>&1; then
    while iptables -C INPUT -j REMNA_GUARD >/dev/null 2>&1; do iptables -D INPUT -j REMNA_GUARD || break; done
    while iptables -C FORWARD -j REMNA_GUARD >/dev/null 2>&1; do iptables -D FORWARD -j REMNA_GUARD || break; done
    iptables -F REMNA_GUARD >/dev/null 2>&1 || true
    iptables -X REMNA_GUARD >/dev/null 2>&1 || true

    for parent in INPUT FORWARD OUTPUT; do
      while iptables -C "$parent" -j TSPUIPS >/dev/null 2>&1; do iptables -D "$parent" -j TSPUIPS || break; done
    done
    iptables -F TSPUIPS >/dev/null 2>&1 || true
    iptables -X TSPUIPS >/dev/null 2>&1 || true
  fi

  if command -v ip6tables >/dev/null 2>&1; then
    while ip6tables -C INPUT -j REMNA_GUARD6 >/dev/null 2>&1; do ip6tables -D INPUT -j REMNA_GUARD6 || break; done
    while ip6tables -C FORWARD -j REMNA_GUARD6 >/dev/null 2>&1; do ip6tables -D FORWARD -j REMNA_GUARD6 || break; done
    ip6tables -F REMNA_GUARD6 >/dev/null 2>&1 || true
    ip6tables -X REMNA_GUARD6 >/dev/null 2>&1 || true
  fi

  if command -v ipset >/dev/null 2>&1; then
    local setname
    for setname in REMNA_TSPU REMNA_GOV REMNA_ALLOW REMNA_DENY REMNA_COUNTRY_ALLOW TSPUIPS; do
      ipset destroy "$setname" >/dev/null 2>&1 || true
    done
  fi

  if [ -n "$panel_ip" ] && command -v ufw >/dev/null 2>&1; then
    ufw --force delete allow from "$panel_ip" to any port 2222 proto tcp >/dev/null 2>&1 || true
  fi

  ok "Remna/RKN firewall chains/ipsets удалены адресно; глобальный firewall не сбрасывался."
}

remove_node_runtime(){
  if command -v docker >/dev/null 2>&1; then
    if [ -f "$NODE_DIR/docker-compose.yml" ]; then
      ( cd "$NODE_DIR" && docker compose down --remove-orphans ) >/dev/null 2>&1 || true
    fi
    docker rm -f remnanode >/dev/null 2>&1 || true
  fi

  rm -rf "$NODE_DIR"
  ok "Контейнер remnanode и $NODE_DIR удалены. Остальные Docker-контейнеры не тронуты."
}

remove_front_runtime(){
  run_quiet systemctl stop caddy
  rm -f "$CADDY_DIR/Caddyfile" "$CADDY_DIR/Caddyfile.public" "$CADDY_DIR/Caddyfile.reality"
  rm -rf "$WEBROOT"
  ok "Конфиги Caddy и стрим-сайт удалены; пакет Caddy и его ACME-cache сохранены."
}

remove_hysteria_runtime(){
  local found=0
  if [ -f /etc/systemd/system/hysteria-server.service ] || [ -d /etc/hysteria ]; then
    found=1
    remove_unit hysteria-server.service
    rm -rf /etc/hysteria
  fi
  if [ -f /etc/systemd/system/hysteria2.service ] || [ -d /etc/hysteria2 ]; then
    found=1
    remove_unit hysteria2.service
    rm -rf /etc/hysteria2
  fi
  if [ -d /opt/remna-hysteria ]; then
    found=1
    rm -rf /opt/remna-hysteria
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  if [ "$found" -eq 1 ]; then
    ok "Найдены и удалены старые Hysteria-конфиги/units, относящиеся к node stack."
  else
    ok "Старых Hysteria units/configs не найдено."
  fi
}

remove_stale_remna_files(){
  rm -rf "$PROTECTION_DIR" "$PROTECTION_LOG"
  rm -f \
    "$INSTALL_DIR/rkn-watcher.sh" \
    "$INSTALL_DIR/rkn-scanner.sh" \
    "$INSTALL_DIR/remnanode-rkn-scanner.sh" \
    "$INSTALL_DIR/remna-rkn-watcher.sh" \
    "$INSTALL_DIR/caddy-resilient-start.sh"
  ok "Старые Remna protection/RKN helper-файлы очищены."
}

postcheck(){
  local sshsvc failed=0
  sshsvc="$(ssh_service_name)"

  systemctl is-active --quiet "$sshsvc" || { warn "SSH service $sshsvc НЕ активен после очистки."; failed=1; }
  ssh_listener_present || { warn "sshd НЕ слушает после очистки."; failed=1; }
  ip route show default 2>/dev/null | grep -q '^default ' || { warn "После очистки пропал default route."; failed=1; }

  if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
    warn "Контейнер remnanode всё ещё существует."
    failed=1
  fi

  if ss -lntp 2>/dev/null | grep -E ':80[[:space:]]|:443[[:space:]]' | grep -Eq 'caddy|rw-core|xray|hysteria'; then
    warn "80/443 всё ещё заняты старым Caddy/Xray/Hysteria:"
    ss -lntp 2>/dev/null | grep -E ':80[[:space:]]|:443[[:space:]]' | grep -E 'caddy|rw-core|xray|hysteria' || true
    failed=1
  fi

  if [ "$failed" -eq 0 ]; then
    ok "POSTCHECK PASS: SSH/сеть сохранены, remnanode удалён, 80/443 свободны от старого node stack."
    return 0
  fi

  warn "POSTCHECK FAIL: новую установку автоматически не запускаю. Recovery bundle: $BACKUP_DIR"
  return 1
}

confirm_clean(){
  [ "$ASSUME_YES" = 1 ] && return 0
  say "Будут удалены локальные Remnanode/Caddy-конфиги/RKN protection/Hysteria-конфиги старого node stack."
  say "НЕ будут затронуты: SSH, network config, hostname, DNS, Docker как пакет и чужие Docker-контейнеры."
  printf 'Для продолжения введи CLEAN: '
  local answer=""
  read -r answer < "$TTY" || true
  [ "$answer" = CLEAN ] || die "Очистка отменена."
}

full_clean(){
  preflight
  confirm_clean
  make_backup
  remove_matching_remna_units
  remove_protection_firewall
  remove_node_runtime
  remove_hysteria_runtime
  remove_front_runtime
  remove_stale_remna_files
  postcheck
}

install_fresh(){
  command -v curl >/dev/null 2>&1 || { apt-get update -y && apt-get install -y curl ca-certificates; }
  install -d -m 0755 "$INSTALL_DIR"
  local tmp
  tmp="$(mktemp)"
  if ! curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 "$MANAGER_URL" -o "$tmp"; then
    rm -f "$tmp"
    die "Не удалось скачать свежий installer."
    return 1
  fi
  bash -n "$tmp" || { rm -f "$tmp"; die "Свежий installer не прошёл bash -n."; return 1; }
  install -o root -g root -m 0700 "$tmp" "$MANAGER_PATH"
  rm -f "$tmp"
  ok "Свежий manager установлен: $MANAGER_PATH"
  bash "$MANAGER_PATH" install
}

show_menu(){
  say "[1] Только полный CLEAN"
  say "[2] Полный CLEAN -> свежая установка"
  say "[0] Отмена"
  printf 'Выбор: '
  local choice=""
  read -r choice < "$TTY" || true
  case "$choice" in
    1) full_clean ;;
    2) full_clean && install_fresh ;;
    0|'') die "Отменено." ;;
    *) die "Неизвестный пункт: $choice" ;;
  esac
}

case "$MODE" in
  clean) full_clean ;;
  reinstall|full-reinstall) full_clean && install_fresh ;;
  menu|'') show_menu ;;
  *) die "Использование: $0 [clean|reinstall]" ;;
esac
