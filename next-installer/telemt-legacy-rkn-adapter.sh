#!/usr/bin/env bash
set -Eeuo pipefail

LEGACY_RKN="${LEGACY_RKN:-/opt/remnanode/next-installer/rkn-watcher-manager.sh}"
TELEMT_PORT="${TELEMT_PORT:-8443}"
BACKUP_DIR="${BACKUP_DIR:-/root/remna-telemt-legacy-backup}"

die(){ echo "[ERROR] $*" >&2; exit 1; }
info(){ echo "[INFO] $*"; }
need_root(){ [ "$(id -u)" -eq 0 ] || die "run as root"; }

preflight(){
  [ -x "$LEGACY_RKN" ] || die "legacy RKN manager not found: $LEGACY_RKN"
  [[ "$TELEMT_PORT" =~ ^[0-9]+$ ]] || die "invalid TELEMT_PORT"
  [ "$TELEMT_PORT" -ge 1024 ] && [ "$TELEMT_PORT" -le 65535 ] || die "invalid TELEMT_PORT"
  grep -Fq -- '--dports 80,443' "$LEGACY_RKN" || grep -Fq -- "--dports 80,443,$TELEMT_PORT" "$LEGACY_RKN" || die "unexpected legacy guard shape"
  ipset list TSPUIPS >/dev/null 2>&1 || die "TSPUIPS is missing"
  iptables -S REMNA_RKN_SCANNERS >/dev/null 2>&1 || die "REMNA_RKN_SCANNERS is missing"
  info "legacy RKN preflight OK"
}

backup(){
  mkdir -p "$BACKUP_DIR"
  chmod 0700 "$BACKUP_DIR"
  [ -f "$BACKUP_DIR/rkn-watcher-manager.sh.before-telemt" ] || cp -a "$LEGACY_RKN" "$BACKUP_DIR/rkn-watcher-manager.sh.before-telemt"
  iptables-save > "$BACKUP_DIR/iptables.before-telemt"
  ip6tables-save > "$BACKUP_DIR/ip6tables.before-telemt"
  ipset save > "$BACKUP_DIR/ipset.before-telemt"
  ufw status numbered > "$BACKUP_DIR/ufw.before-telemt" 2>/dev/null || true
}

apply(){
  need_root
  preflight
  backup
  python3 - "$LEGACY_RKN" "$TELEMT_PORT" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
port=sys.argv[2]
s=p.read_text()
old="--dports 80,443 "
new=f"--dports 80,443,{port} "
if new not in s:
    if old not in s:
        raise SystemExit("legacy guard rule anchor missing")
    s=s.replace(old,new)
old_msg="DROP tcp/80,tcp/443,udp/443"
new_msg=f"DROP tcp/80,tcp/443,tcp/{port},udp/443"
s=s.replace(old_msg,new_msg)
p.write_text(s)
PY
  chmod 0700 "$LEGACY_RKN"
  "$LEGACY_RKN" apply
  iptables -S REMNA_RKN_SCANNERS | grep -Fq -- "--dports 80,443,$TELEMT_PORT" || die "legacy guard did not cover TCP/$TELEMT_PORT"
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    if ! ufw status | grep -Eq "^$TELEMT_PORT/tcp[[:space:]]+ALLOW IN"; then
      ufw allow "$TELEMT_PORT/tcp" comment 'Telemt MTProto' >/dev/null
    fi
  fi
  info "legacy RKN guard covers TCP/$TELEMT_PORT; UFW admission ensured"
}

status(){
  preflight
  iptables -S REMNA_RKN_SCANNERS | grep -E -- "--dports .*($TELEMT_PORT|443)" || true
  ufw status 2>/dev/null | grep -E "^$TELEMT_PORT/tcp" || true
}

rollback(){
  need_root
  [ -f "$BACKUP_DIR/rkn-watcher-manager.sh.before-telemt" ] || die "backup not found"
  cp -a "$BACKUP_DIR/rkn-watcher-manager.sh.before-telemt" "$LEGACY_RKN"
  "$LEGACY_RKN" apply
  if command -v ufw >/dev/null 2>&1; then
    ufw --force delete allow "$TELEMT_PORT/tcp" >/dev/null 2>&1 || true
  fi
  info "legacy RKN manager restored; Telemt UFW admission removed"
}

case "${1:-status}" in
  preflight) preflight ;;
  apply) apply ;;
  status) status ;;
  rollback) rollback ;;
  *) echo "Usage: $0 {preflight|apply|status|rollback}" ;;
esac
