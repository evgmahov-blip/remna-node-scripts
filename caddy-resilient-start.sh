#!/usr/bin/env bash
set -Eeuo pipefail

SELF=/opt/remna-node-scripts/caddy-resilient-start.sh
DROPIN_DIR=/etc/systemd/system/caddy.service.d
DROPIN=$DROPIN_DIR/10-remna-topology-guard.conf
CADDYFILE=${CADDYFILE:-/etc/caddy/Caddyfile}
CADDY_PUBLIC=${CADDY_PUBLIC:-/etc/caddy/Caddyfile.public}
CADDY_REALITY=${CADDY_REALITY:-/etc/caddy/Caddyfile.reality}
CADDY_LOCAL_PORT=${CADDY_LOCAL_PORT:-8443}

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO=sudo; fi
say(){ printf '%s\n' "$*"; }
ok(){ printf '✓ %s\n' "$*"; }
warn(){ printf '! %s\n' "$*" >&2; }
die(){ printf '✗ %s\n' "$*" >&2; exit 1; }

rw_core_on_443(){
  ss -lntp 2>/dev/null | grep -E ':443[[:space:]]' | grep -q 'rw-core'
}

caddy_on_443(){
  ss -lntp 2>/dev/null | grep -E ':443[[:space:]]' | grep -q 'caddy'
}

caddy_on_8443(){
  ss -lntp 2>/dev/null | grep -E "127\\.0\\.0\\.1:${CADDY_LOCAL_PORT}[[:space:]]" | grep -q 'caddy'
}

validate(){
  [ -s "$1" ] && $SUDO caddy validate --config "$1" --adapter caddyfile >/dev/null 2>&1
}

make_local_fallback(){
  local src tmp
  src="$CADDY_PUBLIC"
  [ -s "$src" ] || src="$CADDYFILE"
  [ -s "$src" ] || return 1
  tmp=$(mktemp)

  awk -v p="$CADDY_LOCAL_PORT" '
    BEGIN { global=0; site=0; inserted_global=0; inserted_bind=0 }
    /^[[:space:]]*\{[[:space:]]*$/ && !global && !site {
      print
      print "  https_port " p
      print "  default_bind 127.0.0.1"
      global=1; inserted_global=1; next
    }
    global && /^[[:space:]]*\}[[:space:]]*$/ { print; global=0; next }
    !global && /^[A-Za-z0-9.-]+[[:space:]]*\{[[:space:]]*$/ {
      print
      print "  bind 127.0.0.1"
      site=1; inserted_bind=1; next
    }
    { print }
    END { if (!inserted_global || !inserted_bind) exit 42 }
  ' "$src" > "$tmp" || { rm -f "$tmp"; return 1; }

  $SUDO caddy fmt --overwrite "$tmp" >/dev/null 2>&1 || true
  validate "$tmp" || { rm -f "$tmp"; return 1; }
  $SUDO install -o root -g root -m 0644 "$tmp" "$CADDY_REALITY"
  rm -f "$tmp"
}

prepare(){
  command -v caddy >/dev/null 2>&1 || return 0
  command -v ss >/dev/null 2>&1 || return 0

  # IMPORTANT: XHTTP :7443 is intentionally NOT checked here.
  # Caddy topology depends only on who owns external TCP/443.
  if rw_core_on_443; then
    if ! validate "$CADDY_REALITY"; then
      make_local_fallback || die "rw-core держит :443, но не удалось подготовить локальный Caddy :${CADDY_LOCAL_PORT}."
    fi
    $SUDO install -o root -g root -m 0644 "$CADDY_REALITY" "$CADDYFILE"
    say "CADDY_PREPARE=local:${CADDY_LOCAL_PORT} reason=rw-core:443"
    return 0
  fi

  # No REALITY listener => Caddy owns public HTTPS. Missing XHTTP is harmless
  # for Caddy itself: only the tunnel route can be unavailable/502.
  if validate "$CADDY_PUBLIC"; then
    $SUDO install -o root -g root -m 0644 "$CADDY_PUBLIC" "$CADDYFILE"
    say 'CADDY_PREPARE=public:443 reason=no-rw-core'
    return 0
  fi

  # First install may not have Caddyfile.public yet. Keep the just-generated
  # Caddyfile if it validates.
  if validate "$CADDYFILE"; then
    say 'CADDY_PREPARE=current reason=no-public-backup-yet'
    return 0
  fi

  die "Нет валидного Caddyfile для безопасного запуска."
}

install_guard(){
  command -v systemctl >/dev/null 2>&1 || die "systemd/systemctl не найден."
  $SUDO install -d -o root -g root -m 0755 /opt/remna-node-scripts "$DROPIN_DIR"

  local current
  current="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  if [ "$current" != "$SELF" ]; then
    $SUDO install -o root -g root -m 0700 "$current" "$SELF"
  else
    $SUDO chmod 0700 "$SELF"
  fi

  local tmp
  tmp=$(mktemp)
  cat > "$tmp" <<EOF
[Service]
ExecStartPre=$SELF prepare
EOF
  $SUDO install -o root -g root -m 0644 "$tmp" "$DROPIN"
  rm -f "$tmp"

  $SUDO systemctl daemon-reload
  prepare
  $SUDO systemctl enable caddy >/dev/null 2>&1 || true
  if ! $SUDO systemctl restart caddy; then
    $SUDO journalctl -u caddy -n 50 --no-pager 2>/dev/null || true
    die "Caddy не запустился даже с topology guard."
  fi
  sleep 1

  if rw_core_on_443; then
    caddy_on_8443 || die "Guard выбран local mode, но Caddy не слушает 127.0.0.1:${CADDY_LOCAL_PORT}."
    ok "Guard установлен: rw-core :443 → Caddy 127.0.0.1:${CADDY_LOCAL_PORT}."
  else
    caddy_on_443 || die "Guard выбран public mode, но Caddy не слушает :443."
    ok "Guard установлен: REALITY отсутствует → Caddy :443."
  fi
}

remove_guard(){
  $SUDO rm -f "$DROPIN"
  $SUDO systemctl daemon-reload
  ok "Caddy topology guard удалён."
}

status(){
  printf 'Guard       : %s\n' "$([ -s "$DROPIN" ] && echo installed || echo absent)"
  printf 'rw-core :443: %s\n' "$(rw_core_on_443 && echo yes || echo no)"
  printf 'Caddy :443  : %s\n' "$(caddy_on_443 && echo yes || echo no)"
  printf 'Caddy :8443 : %s\n' "$(caddy_on_8443 && echo yes || echo no)"
  if ss -lntp 2>/dev/null | grep -E '127\.0\.0\.1:7443[[:space:]]' | grep -q rw-core; then
    echo 'XHTTP :7443  : yes (does not affect Caddy mode)'
  else
    echo 'XHTTP :7443  : no  (does not affect Caddy mode)'
  fi
}

case "${1:-status}" in
  prepare) prepare ;;
  install|enable) install_guard ;;
  remove|disable) remove_guard ;;
  status) status ;;
  *) die "Использование: $0 {install|prepare|status|remove}" ;;
esac
