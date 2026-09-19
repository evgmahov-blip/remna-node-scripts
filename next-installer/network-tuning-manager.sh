#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

TASK_NAME="REMNANODE NETWORK / BBR"
TTY=/dev/tty
[[ -r "$TTY" ]] || TTY=/dev/stdin

IVAN_REPO="https://github.com/ivan-nginx/bbr3"
IVAN_REF="faabcb8b4070742acc01955283130b386bb07b68"
BALBUTO_REPO="https://github.com/Balbuto/safe-remnanode-setup"
BALBUTO_REF="274d84d9daa3b4d4a33264ba77992210aedd9b32"

BBR3_INSTALLER_REPO="XDflight/bbr3-debs"
BBR3_INSTALLER_REF="4f7e3b5a14ffd26777c28f364ce49c7c6e02180b"
BBR3_INSTALLER_BLOB_SHA="f8e1ed9bd7663531d8b9bb67ac42fb8de057b47e"
BBR3_INSTALLER_URL="https://raw.githubusercontent.com/${BBR3_INSTALLER_REPO}/${BBR3_INSTALLER_REF}/install_latest.sh"

SYSCTL_TUNE="/etc/sysctl.d/99-remnanode-network.conf"
SYSCTL_BBR3="/etc/sysctl.d/99-remnanode-bbr3.conf"

say(){ printf '%s\n' "$*"; }
ok(){ printf '[OK] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Запусти от root.'; }

git_blob_sha(){
  local file="$1" size
  size="$(wc -c <"$file" | tr -d '[:space:]')"
  { printf 'blob %s\000' "$size"; cat "$file"; } | sha1sum | awk '{print $1}'
}

network_status(){
  echo '================ NETWORK / BBR STATUS ================'
  printf 'Kernel       : %s\n' "$(uname -r 2>/dev/null || echo unknown)"
  printf 'Congestion   : %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  printf 'Available CC : %s\n' "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo unknown)"
  printf 'Qdisc        : %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  printf 'TCP FastOpen : %s\n' "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo unknown)"
  printf 'ECN          : %s\n' "$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null || echo unknown)"
  printf 'rmem_max     : %s\n' "$(sysctl -n net.core.rmem_max 2>/dev/null || echo unknown)"
  printf 'wmem_max     : %s\n' "$(sysctl -n net.core.wmem_max 2>/dev/null || echo unknown)"
  printf 'tcp_rmem     : %s\n' "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo unknown)"
  printf 'tcp_wmem     : %s\n' "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo unknown)"
  echo '======================================================'
}

backup_network_state(){
  local stamp dir
  stamp="$(date +%Y%m%d-%H%M%S)"
  dir="/root/remnanode-network-backup-$stamp"
  mkdir -p "$dir"
  chmod 0700 "$dir"
  cp -a /etc/sysctl.conf "$dir/" 2>/dev/null || true
  cp -a /etc/sysctl.d "$dir/" 2>/dev/null || true
  sysctl -a > "$dir/sysctl-before.txt" 2>/dev/null || true
  uname -a > "$dir/uname-before.txt" 2>/dev/null || true
  dpkg -l > "$dir/dpkg-before.txt" 2>/dev/null || true
  ok "Network backup → $dir"
}

apply_bbr_tune(){
  need_root
  backup_network_state

  local ram_kb ram_gb
  ram_kb="$(awk '/MemTotal/{print $2; exit}' /proc/meminfo)"
  ram_gb=$((ram_kb / 1024 / 1024))
  modprobe tcp_bbr >/dev/null 2>&1 || true

  if (( ram_gb >= 2 )); then
    cat > "$SYSCTL_TUNE" <<'EOF'
# REMNANODE BBR TUNE — HIGHLOAD
# Based on the conservative tuning approach used by Balbuto/safe-remnanode-setup.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
fs.file-max = 2097152
vm.swappiness = 10
vm.max_map_count = 262144
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 16384
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_syncookies = 1
net.netfilter.nf_conntrack_max = 1048576
EOF
    ok "BBR TUNE: HIGHLOAD профиль выбран автоматически (RAM=${ram_gb} GB)."
  else
    cat > "$SYSCTL_TUNE" <<'EOF'
# REMNANODE BBR TUNE — SAFE
# Based on the conservative tuning approach used by Balbuto/safe-remnanode-setup.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
fs.file-max = 524288
vm.swappiness = 10
vm.max_map_count = 262144
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_syncookies = 1
net.netfilter.nf_conntrack_max = 65536
EOF
    ok "BBR TUNE: SAFE профиль выбран автоматически (RAM=${ram_gb} GB)."
  fi

  sysctl --system >/dev/null
  ok "BBR TUNE применён → $SYSCTL_TUNE"
  network_status
}

install_bbr3(){
  need_root

  if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container >/dev/null 2>&1; then
    die 'BBR3 kernel нельзя безопасно ставить внутри контейнера/LXC/OpenVZ. Нужна VM/VPS с собственным ядром.'
  fi
  command -v apt-get >/dev/null 2>&1 || die 'BBR3 installer рассчитан на Debian/Ubuntu с apt/dpkg.'
  command -v dpkg >/dev/null 2>&1 || die 'BBR3 installer требует dpkg.'

  backup_network_state
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update -y
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y curl jq ca-certificates

  local tmp
  tmp="/tmp/remnanode-bbr3-install.sh"
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 90 --retry 3 \
    "$BBR3_INSTALLER_URL" -o "$tmp" || die 'Не удалось скачать pinned BBR3 installer.'
  [[ "$(git_blob_sha "$tmp")" == "$BBR3_INSTALLER_BLOB_SHA" ]] || die 'BBR3 installer не прошёл Git blob SHA.'
  chmod 0700 "$tmp"

  echo
  echo '================ BBR3: МЕНЯЕТ ЯДРО ================'
  echo "Source idea/profile : $IVAN_REPO"
  echo "Pinned ivan commit  : $IVAN_REF"
  echo "Pinned installer    : https://github.com/$BBR3_INSTALLER_REPO"
  echo "Pinned installer ref: $BBR3_INSTALLER_REF"
  echo 'Будет установлен отдельный BBR3 kernel. Автоматический reboot отключён.'
  echo '===================================================='

  bash "$tmp" --no

  cat > "$SYSCTL_BBR3" <<'EOF'
# REMNANODE BBR3 profile
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_ecn = 1
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
EOF
  sysctl --system >/dev/null 2>&1 || true

  echo
  ok 'BBR3 kernel package установлен. Для фактического перехода на новое ядро нужен reboot.'
  echo 'ПОСЛЕ REBOOT ПРОВЕРИТЬ: sudo remnanode-next network-status'
  echo
  network_status
}

show_sources(){
  cat <<EOF
================ ИСТОЧНИКИ / ССЫЛКИ ================
BBR3:
  $IVAN_REPO
  pinned commit: $IVAN_REF

BBR TUNE / SAFE-HIGHLOAD:
  $BALBUTO_REPO
  pinned reference commit: $BALBUTO_REF

Команды REMNANODE NEXT:
  sudo remnanode-next network
  sudo remnanode-next network-status
  sudo remnanode-next bbr-tune
  sudo remnanode-next bbr3
=====================================================
EOF
}

menu(){
  local c
  while true; do
    cat <<EOF

================ СЕТЬ / BBR / BBR3 =================
 [1] ПОКАЗАТЬ ТЕКУЩЕЕ СОСТОЯНИЕ
 [2] BBR TUNE — SAFE/HIGHLOAD, БЕЗ ЗАМЕНЫ ЯДРА
     SOURCE: $BALBUTO_REPO
     RUN:    sudo remnanode-next bbr-tune

 [3] BBR3 — КАСТОМНОЕ ЯДРО, НУЖЕН REBOOT
     SOURCE: $IVAN_REPO
     RUN:    sudo remnanode-next bbr3

 [4] ПОКАЗАТЬ ССЫЛКИ / КОМАНДЫ
 [0] НАЗАД

 БЫСТРЫЙ ВХОД В ЭТО МЕНЮ:
 sudo remnanode-next network
=====================================================
EOF
    printf 'Выбор: '
    read -r c < "$TTY" || true
    case "$c" in
      1) network_status ;;
      2) apply_bbr_tune ;;
      3) install_bbr3 ;;
      4) show_sources ;;
      0|'') return 0 ;;
      *) warn 'Неверный пункт.' ;;
    esac
  done
}

main(){
  need_root
  case "${1:-menu}" in
    menu|'') menu ;;
    status) network_status ;;
    tune|bbr-tune) apply_bbr_tune ;;
    bbr3) install_bbr3 ;;
    sources|links) show_sources ;;
    *) die 'Использование: network-tuning-manager.sh [menu|status|tune|bbr3|sources]' ;;
  esac
}

main "$@"
