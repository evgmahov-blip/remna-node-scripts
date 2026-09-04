#!/usr/bin/env bash
set -Eeuo pipefail

CADDYFILE=${CADDYFILE:-/etc/caddy/Caddyfile}
CADDY_PUBLIC=${CADDY_PUBLIC:-/etc/caddy/Caddyfile.public}
CADDY_REALITY=${CADDY_REALITY:-/etc/caddy/Caddyfile.reality}
CADDY_LOCAL_PORT=${CADDY_LOCAL_PORT:-8443}

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO=sudo; fi

say(){ printf '%s\n' "$*"; }
warn(){ printf '! %s\n' "$*" >&2; }

port443_owner(){
  ss -lntp 2>/dev/null | awk '/:443[[:space:]]/ {print; exit}'
}

rw_core_on_443(){ port443_owner | grep -q 'rw-core'; }
caddy_on_443(){ port443_owner | grep -q 'caddy'; }
caddy_on_8443(){ ss -lntp 2>/dev/null | grep -E "127\\.0\\.0\\.1:${CADDY_LOCAL_PORT}[[:space:]]" | grep -q caddy; }

validate(){ $SUDO caddy validate --config "$1" --adapter caddyfile >/dev/null 2>&1; }

make_local_fallback(){
  local src tmp
  src="$CADDY_PUBLIC"
  [ -s "$src" ] || src="$CADDYFILE"
  [ -s "$src" ] || return 1
  tmp=$(mktemp)

  # Convert the normal public Caddyfile into a localhost-only HTTPS listener.
  # This keeps the decoy/site alive when rw-core already owns external :443.
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

use_local(){
  if [ ! -s "$CADDY_REALITY" ] || ! validate "$CADDY_REALITY"; then
    make_local_fallback || return 1
  fi
  $SUDO install -o root -g root -m 0644 "$CADDY_REALITY" "$CADDYFILE"
  $SUDO systemctl restart caddy >/dev/null 2>&1 || return 1
  sleep 1
  caddy_on_8443
}

use_public(){
  [ -s "$CADDY_PUBLIC" ] || return 1
  validate "$CADDY_PUBLIC" || return 1
  $SUDO install -o root -g root -m 0644 "$CADDY_PUBLIC" "$CADDYFILE"
  $SUDO systemctl restart caddy >/dev/null 2>&1 || return 1
  sleep 1
  caddy_on_443
}

main(){
  command -v caddy >/dev/null 2>&1 || return 0
  command -v ss >/dev/null 2>&1 || return 0
  $SUDO systemctl enable caddy >/dev/null 2>&1 || true

  if rw_core_on_443; then
    # REALITY exists. XHTTP :7443 may exist or may be missing; that must never
    # decide whether Caddy lives. Caddy simply serves localhost:8443.
    if use_local; then
      say "CADDY_MODE=local:${CADDY_LOCAL_PORT} (rw-core owns :443)"
      return 0
    fi
    warn "rw-core owns :443 and local Caddy configuration could not be started."
    return 1
  fi

  # No REALITY inbound currently owns :443. Keep Caddy public even if XHTTP
  # :7443 is absent; the site stays up and only the tunnel route may return 502.
  if caddy_on_443 && $SUDO systemctl is-active --quiet caddy; then
    say 'CADDY_MODE=public:443'
    return 0
  fi
  if use_public; then
    say 'CADDY_MODE=public:443 (no rw-core on :443)'
    return 0
  fi

  warn "Caddy could not be started in either safe topology."
  return 1
}

main "$@"
