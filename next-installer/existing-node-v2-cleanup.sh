#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

TASK_NAME="REMNA NODE EXISTING-NODE V2 CLEANUP"
APP_DIR="/opt/remnanode"
INSTALL_DIR="/opt/remna-node-scripts"
PROTECTION_DIR="/opt/remna-protection"
PROTECTION_LOG="/var/log/remna-protection"
WEBROOT="/var/www/mstream"
CADDY_DIR="/etc/caddy"
CADDY_DROPIN="/etc/systemd/system/caddy.service.d/10-remna-topology-guard.conf"
BACKUP_ROOT="/root/remna-node-v2-backups"
TTY=/dev/tty
[[ -r "$TTY" ]] || TTY=/dev/stdin
ASSUME_YES="${V2_ASSUME_YES:-0}"

say(){ printf '%s\n' "$*"; }
ok(){ printf '[OK] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
run_quiet(){ "$@" >/dev/null 2>&1 || true; }

need_root(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Запусти от root.'
}

ssh_service_name(){
  if systemctl list-unit-files ssh.service >/dev/null 2>&1; then printf 'ssh\n'; return 0; fi
  if systemctl list-unit-files sshd.service >/dev/null 2>&1; then printf 'sshd\n'; return 0; fi
  return 1
}

ssh_listener_present(){
  ss -lntp 2>/dev/null | grep -qE 'LISTEN.+sshd' ||
    ss -lntp 2>/dev/null | grep -qE ':(22|[0-9]{4,5})[[:space:]].*sshd'
}

preflight(){
  local c sshsvc
  for c in systemctl ss ip tar; do
    command -v "$c" >/dev/null 2>&1 || die "V2 preflight: не найден $c"
  done
  sshsvc="$(ssh_service_name 2>/dev/null || true)"
  [[ -n "$sshsvc" ]] || die 'V2 preflight: не найден ssh/sshd systemd unit.'
  systemctl is-active --quiet "$sshsvc" || die "V2 preflight: SSH service $sshsvc не активен."
  ssh_listener_present || die 'V2 preflight: не вижу слушающий sshd.'
  ip route show default 2>/dev/null | grep -q '^default ' || die 'V2 preflight: нет default route.'
  ok 'V2 preflight PASS: SSH активен, sshd слушает, default route есть.'
}

copy_if_exists(){
  local src="$1" dst="$2" rel
  [[ -e "$src" ]] || return 0
  rel="${src#/}"
  mkdir -p "$dst/$(dirname "$rel")"
  cp -a "$src" "$dst/$rel" 2>/dev/null || warn "Backup: не удалось скопировать $src"
}

make_backup(){
  local stamp dir archive unit
  stamp="$(date +%Y%m%d-%H%M%S)"
  dir="$BACKUP_ROOT/$stamp"
  archive="$BACKUP_ROOT/remna-node-v2-$stamp.tar.gz"
  umask 077
  mkdir -p "$dir/state"

  copy_if_exists "$APP_DIR" "$dir"
  copy_if_exists "$INSTALL_DIR" "$dir"
  copy_if_exists "$PROTECTION_DIR" "$dir"
  copy_if_exists "$PROTECTION_LOG" "$dir"
  copy_if_exists "$WEBROOT" "$dir"
  copy_if_exists "$CADDY_DIR/Caddyfile" "$dir"
  copy_if_exists "$CADDY_DIR/Caddyfile.public" "$dir"
  copy_if_exists "$CADDY_DIR/Caddyfile.reality" "$dir"
  copy_if_exists "$CADDY_DROPIN" "$dir"
  copy_if_exists /etc/hysteria "$dir"
  copy_if_exists /etc/hysteria2 "$dir"
  copy_if_exists /opt/remna-hysteria "$dir"

  for unit in     hysteria-server.service     hysteria2.service     remna-profile-wait.service     remna-reality-handoff.service     remna-reality-handoff.timer     remna-protection.service     remna-protection-update.service     remna-protection-update.timer     remnanode-rkn-scanner-boot.service     remnanode-rkn-scanner-update.service     remnanode-rkn-scanner-update.timer     remnanode-rkn-scanner-health.service     remnanode-rkn-scanner-health.timer     remnanode-rkn-scanner-ufw.path     remnanode-rkn-watcher.service     remnanode-rkn-watcher.timer     remna-rkn-watcher.service     remna-rkn-watcher.timer
  do
    copy_if_exists "/etc/systemd/system/$unit" "$dir"
  done

  systemctl list-unit-files --no-pager > "$dir/state/systemd-unit-files.txt" 2>&1 || true
  systemctl --no-pager --all status ssh sshd caddy > "$dir/state/service-status.txt" 2>&1 || true
  ss -lntup > "$dir/state/listening-ports.txt" 2>&1 || true
  ip addr show > "$dir/state/ip-address.txt" 2>&1 || true
  ip route show table all > "$dir/state/ip-routes.txt" 2>&1 || true
  ip rule show > "$dir/state/ip-rules.txt" 2>&1 || true
  command -v docker >/dev/null 2>&1 && docker ps -a --no-trunc > "$dir/state/docker-ps.txt" 2>&1 || true
  command -v docker >/dev/null 2>&1 && docker network ls > "$dir/state/docker-networks.txt" 2>&1 || true
  command -v iptables-save >/dev/null 2>&1 && iptables-save > "$dir/state/iptables-save.txt" 2>&1 || true
  command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > "$dir/state/ip6tables-save.txt" 2>&1 || true
  command -v ipset >/dev/null 2>&1 && ipset save > "$dir/state/ipset-save.txt" 2>&1 || true
  command -v ufw >/dev/null 2>&1 && ufw status numbered > "$dir/state/ufw-status-numbered.txt" 2>&1 || true

  if tar -C "$BACKUP_ROOT" -czf "$archive" "$stamp"; then
    chmod 0600 "$archive"
    ok "Recovery backup → $archive"
  else
    warn "tar.gz создать не удалось; backup directory сохранён: $dir"
  fi
  chmod -R go-rwx "$dir" 2>/dev/null || true
}

remove_unit(){
  local unit="$1"
  run_quiet systemctl disable --now "$unit"
  rm -f "/etc/systemd/system/$unit"
}

remove_legacy_units(){
  local unit
  for unit in     remna-profile-wait.service     remna-reality-handoff.service     remna-reality-handoff.timer     remna-protection.service     remna-protection-update.service     remna-protection-update.timer     remnanode-rkn-scanner-boot.service     remnanode-rkn-scanner-update.service     remnanode-rkn-scanner-update.timer     remnanode-rkn-scanner-health.service     remnanode-rkn-scanner-health.timer     remnanode-rkn-scanner-ufw.path     remnanode-rkn-watcher.service     remnanode-rkn-watcher.timer     remna-rkn-watcher.service     remna-rkn-watcher.timer
  do
    remove_unit "$unit"
  done

  rm -f "$CADDY_DROPIN"
  rmdir /etc/systemd/system/caddy.service.d 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true
  ok 'Старые Remna/RKN units и Caddy topology drop-in удалены.'
}

remove_rkn_watchers(){
  local helper
  helper="$APP_DIR/next-installer/next-runtime-guards.sh"
  [[ -x "$helper" ]] && "$helper" remove-rkn-watch >/dev/null 2>&1 || true
  helper="$APP_DIR/next-installer/rkn-watcher-manager.sh"
  [[ -x "$helper" ]] && "$helper" uninstall >/dev/null 2>&1 || true
  helper="$INSTALL_DIR/protection-manager.sh"
  [[ -x "$helper" ]] && "$helper" uninstall >/dev/null 2>&1 || true
}

remove_legacy_firewall(){
  local panel_ip="" parent setname

  [[ -r "$APP_DIR/.panel_ip" ]] && panel_ip="$(tr -d '[:space:]' < "$APP_DIR/.panel_ip")"
  if [[ -z "$panel_ip" && -r "$PROTECTION_DIR/settings.conf" ]]; then
    panel_ip="$(awk -F= '$1=="PANEL_IP"{print $2; exit}' "$PROTECTION_DIR/settings.conf" 2>/dev/null || true)"
  fi

  remove_rkn_watchers

  if command -v iptables >/dev/null 2>&1; then
    for parent in INPUT FORWARD; do
      while iptables -C "$parent" -j REMNA_GUARD >/dev/null 2>&1; do iptables -D "$parent" -j REMNA_GUARD || break; done
    done
    iptables -F REMNA_GUARD >/dev/null 2>&1 || true
    iptables -X REMNA_GUARD >/dev/null 2>&1 || true

    while iptables -C INPUT -j REMNA_RKN_SCANNERS >/dev/null 2>&1; do iptables -D INPUT -j REMNA_RKN_SCANNERS || break; done
    iptables -F REMNA_RKN_SCANNERS >/dev/null 2>&1 || true
    iptables -X REMNA_RKN_SCANNERS >/dev/null 2>&1 || true

    for parent in INPUT FORWARD OUTPUT; do
      while iptables -C "$parent" -j TSPUIPS >/dev/null 2>&1; do iptables -D "$parent" -j TSPUIPS || break; done
    done
    iptables -F TSPUIPS >/dev/null 2>&1 || true
    iptables -X TSPUIPS >/dev/null 2>&1 || true
  fi

  if command -v ip6tables >/dev/null 2>&1; then
    for parent in INPUT FORWARD; do
      while ip6tables -C "$parent" -j REMNA_GUARD6 >/dev/null 2>&1; do ip6tables -D "$parent" -j REMNA_GUARD6 || break; done
    done
    ip6tables -F REMNA_GUARD6 >/dev/null 2>&1 || true
    ip6tables -X REMNA_GUARD6 >/dev/null 2>&1 || true
  fi

  if command -v ipset >/dev/null 2>&1; then
    for setname in REMNA_TSPU REMNA_GOV REMNA_ALLOW REMNA_DENY REMNA_COUNTRY_ALLOW TSPUIPS; do
      ipset destroy "$setname" >/dev/null 2>&1 || true
    done
  fi

  if [[ -n "$panel_ip" ]] && command -v ufw >/dev/null 2>&1; then
    ufw --force delete allow from "$panel_ip" to any port 2222 proto tcp >/dev/null 2>&1 || true
  fi

  ok 'Remna/RKN firewall chains/ipsets удалены адресно; global UFW reset НЕ выполнялся.'
}

stop_node_runtime(){
  if command -v docker >/dev/null 2>&1; then
    if [[ -f "$APP_DIR/docker-compose.yml" ]]; then
      ( cd "$APP_DIR" && docker compose down --remove-orphans ) >/dev/null 2>&1 || true
    fi
    docker rm -f remnanode remnawave-nginx >/dev/null 2>&1 || true
  fi
  ok 'Старый Remnanode runtime остановлен до снятия защиты TCP/2222.'
}

remove_node_runtime_files(){
  rm -rf "$APP_DIR"
  ok 'Старые Remnanode/NEXT файлы удалены; Docker как пакет и чужие контейнеры не тронуты.'
}

remove_legacy_front(){
  run_quiet systemctl stop caddy
  rm -f     "$CADDY_DIR/Caddyfile"     "$CADDY_DIR/Caddyfile.public"     "$CADDY_DIR/Caddyfile.reality"     "$CADDY_DROPIN"
  rm -rf "$WEBROOT"
  ok 'Старые Caddy node-конфиги и /var/www/mstream удалены; пакет Caddy и ACME cache сохранены.'
}

remove_legacy_hysteria(){
  local found=0
  if [[ -f /etc/systemd/system/hysteria-server.service || -d /etc/hysteria ]]; then
    found=1
    remove_unit hysteria-server.service
    rm -rf /etc/hysteria
  fi
  if [[ -f /etc/systemd/system/hysteria2.service || -d /etc/hysteria2 ]]; then
    found=1
    remove_unit hysteria2.service
    rm -rf /etc/hysteria2
  fi
  if [[ -d /opt/remna-hysteria ]]; then
    found=1
    rm -rf /opt/remna-hysteria
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  if (( found )); then
    ok 'Standalone Hysteria/Hysteria2 legacy runtime удалён.'
  else
    ok 'Standalone Hysteria/Hysteria2 legacy runtime не найден.'
  fi
}

remove_stale_files(){
  rm -rf "$PROTECTION_DIR" "$PROTECTION_LOG"
  rm -f     "$INSTALL_DIR/install-caddy-node-reality-stream.sh"     "$INSTALL_DIR/install-caddy-node-reality-stream-core.sh"     "$INSTALL_DIR/caddy-resilient-start.sh"     "$INSTALL_DIR/protection-manager.sh"     "$INSTALL_DIR/rkn-watcher.sh"     "$INSTALL_DIR/rkn-scanner.sh"     "$INSTALL_DIR/remnanode-rkn-scanner.sh"     "$INSTALL_DIR/remna-rkn-watcher.sh"
  ok 'Legacy Caddy/protection/RKN helper-хвосты удалены.'
}

postcheck(){
  local sshsvc failed=0 name
  sshsvc="$(ssh_service_name 2>/dev/null || true)"

  [[ -n "$sshsvc" ]] && systemctl is-active --quiet "$sshsvc" || { warn 'POSTCHECK: SSH service не активен.'; failed=1; }
  ssh_listener_present || { warn 'POSTCHECK: sshd не слушает.'; failed=1; }
  ip route show default 2>/dev/null | grep -q '^default ' || { warn 'POSTCHECK: пропал default route.'; failed=1; }

  if command -v docker >/dev/null 2>&1; then
    for name in remnanode remnawave-nginx; do
      if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
        warn "POSTCHECK: контейнер $name всё ещё существует."
        failed=1
      fi
    done
  fi

  [[ ! -e "$CADDY_DROPIN" ]] || { warn 'POSTCHECK: старый Caddy topology drop-in остался.'; failed=1; }
  [[ ! -d /etc/hysteria && ! -d /etc/hysteria2 && ! -d /opt/remna-hysteria ]] || { warn 'POSTCHECK: старые Hysteria каталоги остались.'; failed=1; }

  if command -v iptables >/dev/null 2>&1; then
    if iptables -nL REMNA_GUARD >/dev/null 2>&1; then warn 'POSTCHECK: chain REMNA_GUARD остался.'; failed=1; fi
    if iptables -nL REMNA_RKN_SCANNERS >/dev/null 2>&1; then warn 'POSTCHECK: chain REMNA_RKN_SCANNERS остался.'; failed=1; fi
  fi
  if command -v ipset >/dev/null 2>&1 && ipset list TSPUIPS >/dev/null 2>&1; then
    warn 'POSTCHECK: ipset TSPUIPS остался.'
    failed=1
  fi

  if ss -lntup 2>/dev/null | grep -E ':(80|443)[[:space:]]' | grep -Eqi 'caddy|rw-core|xray|hysteria'; then
    warn 'POSTCHECK: старый node stack всё ещё держит 80/443:'
    ss -lntup 2>/dev/null | grep -E ':(80|443)[[:space:]]' | grep -Ei 'caddy|rw-core|xray|hysteria' || true
    failed=1
  fi

  if (( failed == 0 )); then
    ok 'V2 POSTCHECK PASS: legacy stack очищен, SSH/сеть сохранены.'
    return 0
  fi

  warn "V2 POSTCHECK FAIL: свежий NEXT автоматически НЕ запускай; используй recovery backup из $BACKUP_ROOT."
  return 1
}

confirm_cleanup(){
  [[ "$ASSUME_YES" == 1 ]] && return 0
  say 'Будут удалены локальные Remnanode/Caddy/Hysteria/RKN компоненты старого node stack.'
  say 'НЕ будут затронуты: SSH, hostname, DNS, default route, Docker как пакет и чужие Docker-контейнеры.'
  printf 'Для продолжения введи MIGRATE (0 = назад): '
  local answer
  read -r answer < "$TTY" || true
  [[ "$answer" == MIGRATE ]] || die 'V2 cleanup отменён.'
}

main(){
  need_root
  preflight
  confirm_cleanup
  make_backup
  remove_legacy_units
  stop_node_runtime
  remove_legacy_firewall
  remove_node_runtime_files
  remove_legacy_hysteria
  remove_legacy_front
  remove_stale_files
  postcheck
}

main "$@"
