#!/usr/bin/env bash
set -Eeuo pipefail

LEGACY_RKN="${LEGACY_RKN:-/opt/remnanode/next-installer/rkn-watcher-manager.sh}"
TELEMT_PORT="${TELEMT_PORT:-8443}"
BACKUP_DIR="${BACKUP_DIR:-/root/remna-telemt-legacy-backup}"
GUARD_SCRIPT="${GUARD_SCRIPT:-/opt/remnanode/rkn-safe/scanner-guard.sh}"

die(){ echo "[ERROR] $*" >&2; exit 1; }
info(){ echo "[INFO] $*"; }
need_root(){ [ "$(id -u)" -eq 0 ] || die "run as root"; }

preflight(){
  [ -x "$LEGACY_RKN" ] || die "legacy RKN manager not found: $LEGACY_RKN"
  [ -x "$GUARD_SCRIPT" ] || die "legacy scanner guard not found: $GUARD_SCRIPT"
  [[ "$TELEMT_PORT" =~ ^[0-9]+$ ]] || die "invalid TELEMT_PORT"
  [ "$TELEMT_PORT" -ge 1024 ] && [ "$TELEMT_PORT" -le 65535 ] || die "invalid TELEMT_PORT"
  grep -Fq -- '--dports 80,443' "$LEGACY_RKN" || grep -Fq -- "--dports 80,443,$TELEMT_PORT" "$LEGACY_RKN" || die "unexpected legacy manager shape"
  grep -Fq -- '--dports 80,443' "$GUARD_SCRIPT" || grep -Fq -- "--dports 80,443,$TELEMT_PORT" "$GUARD_SCRIPT" || die "unexpected legacy scanner guard shape"
  ipset list TSPUIPS >/dev/null 2>&1 || die "TSPUIPS is missing"
  iptables -S REMNA_RKN_SCANNERS >/dev/null 2>&1 || die "REMNA_RKN_SCANNERS is missing"
  info "legacy RKN preflight OK"
}

backup(){
  mkdir -p "$BACKUP_DIR"
  chmod 0700 "$BACKUP_DIR"
  [ -f "$BACKUP_DIR/rkn-watcher-manager.sh.before-telemt" ] || cp -a "$LEGACY_RKN" "$BACKUP_DIR/rkn-watcher-manager.sh.before-telemt"
  [ -f "$BACKUP_DIR/scanner-guard.sh.before-telemt" ] || cp -a "$GUARD_SCRIPT" "$BACKUP_DIR/scanner-guard.sh.before-telemt"
  iptables-save > "$BACKUP_DIR/iptables.before-telemt"
  ip6tables-save > "$BACKUP_DIR/ip6tables.before-telemt"
  ipset save > "$BACKUP_DIR/ipset.before-telemt"
  ufw status numbered > "$BACKUP_DIR/ufw.before-telemt" 2>/dev/null || true
}

apply(){
  need_root
  preflight
  backup
  python3 - "$LEGACY_RKN" "$GUARD_SCRIPT" "$TELEMT_PORT" <<'PY'
from pathlib import Path
import sys
port=sys.argv[3]
for raw in sys.argv[1:3]:
    p=Path(raw)
    s=p.read_text()
    old="--dports 80,443 "
    new=f"--dports 80,443,{port} "
    if new not in s:
        if old not in s:
            raise SystemExit(f"legacy guard rule anchor missing in {p}")
        s=s.replace(old,new)
    old_msg="DROP tcp/80,tcp/443,udp/443"
    new_msg=f"DROP tcp/80,tcp/443,tcp/{port},udp/443"
    s=s.replace(old_msg,new_msg)
    p.write_text(s)
PY
  chmod 0700 "$LEGACY_RKN" "$GUARD_SCRIPT"
  "$GUARD_SCRIPT" apply
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
  [ -f "$BACKUP_DIR/scanner-guard.sh.before-telemt" ] || die "guard backup not found"
  cp -a "$BACKUP_DIR/scanner-guard.sh.before-telemt" "$GUARD_SCRIPT"
  "$GUARD_SCRIPT" apply
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
