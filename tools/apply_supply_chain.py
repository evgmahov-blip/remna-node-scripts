#!/usr/bin/env python3
from pathlib import Path


def replace(path, old, new, count=1):
    p = Path(path)
    s = p.read_text()
    if old not in s:
        raise SystemExit(f"expected block not found in {path}: {old[:120]!r}")
    p.write_text(s.replace(old, new, count))

core = "install-caddy-node-reality-stream-core.sh"
telemt = "telemt-manager.sh"

# ---- Core: pin Remnawave image and Docker installer ----
replace(core,
'''STREAM_HEALTH_UPSTREAM="${STREAM_HEALTH_UPSTREAM:-https://stream.deepbeat.ru:8443/health}"
''',
'''STREAM_HEALTH_UPSTREAM="${STREAM_HEALTH_UPSTREAM:-https://stream.deepbeat.ru:8443/health}"
REMNA_NODE_IMAGE="${REMNA_NODE_IMAGE:-remnawave/node:3.4.1}"
DOCKER_INSTALL_COMMIT=42dcae692436f34526524ed46d3b32885c9355f5
DOCKER_INSTALL_BLOB_SHA=c67c0e799b42c0435949a3f83785749480d5f14d
DOCKER_INSTALL_URL="https://raw.githubusercontent.com/docker/docker-install/${DOCKER_INSTALL_COMMIT}/install.sh"
''')

replace(core,
'''}

install_prerequisites() {
''',
'''}

git_blob_sha() {
  local file="$1" size
  command -v sha1sum >/dev/null 2>&1 || return 1
  size="$(wc -c <"$file" | tr -d '[:space:]')"
  { printf 'blob %s\\000' "$size"; cat "$file"; } | sha1sum | awk '{print $1}'
}

download_git_blob_checked() {
  local url="$1" expected="$2" dst="$3" actual
  rm -f "$dst"
  curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 "$url" -o "$dst" || { rm -f "$dst"; return 1; }
  actual="$(git_blob_sha "$dst")" || { rm -f "$dst"; return 1; }
  if [ "$actual" != "$expected" ]; then
    warn "Integrity check failed for $url (git blob $actual != $expected)"
    rm -f "$dst"
    return 1
  fi
  sh -n "$dst" || { rm -f "$dst"; return 1; }
  chmod 0700 "$dst"
}

install_prerequisites() {
''')

replace(core,
'''  if ! command -v docker >/dev/null 2>&1; then
    log "Ставлю Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    $SUDO sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
  fi
''',
'''  if ! command -v docker >/dev/null 2>&1; then
    log "Ставлю Docker из зафиксированного официального installer commit..."
    download_git_blob_checked "$DOCKER_INSTALL_URL" "$DOCKER_INSTALL_BLOB_SHA" /tmp/get-docker.sh \\
      || die "Не удалось скачать/проверить Docker installer."
    $SUDO sh /tmp/get-docker.sh
    $SUDO rm -f /tmp/get-docker.sh
  fi
''')

replace(core, '    image: remnawave/node:latest\n', '    image: ${REMNA_NODE_IMAGE}\n')

# ---- Telemt manager: pin upstream installers and versions ----
replace(telemt,
'''PANEL_INSTALL_URL="https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh"
TELEMT_INSTALL_URL="https://raw.githubusercontent.com/telemt/telemt/main/install.sh"
''',
'''TELEMT_VERSION=3.5.5
TELEMT_INSTALL_COMMIT=ac71d92ec41dea00a7eafd6b8d350c3486633500
TELEMT_INSTALL_BLOB_SHA=955c73d4af5c040d174eb8cd4e7d1e22b70f0759
TELEMT_INSTALL_URL="https://raw.githubusercontent.com/telemt/telemt/${TELEMT_INSTALL_COMMIT}/install.sh"
PANEL_VERSION=v0.6.2
PANEL_INSTALL_COMMIT=7a02d77619f2e9df624fa9e05a606fd6b0e16943
PANEL_INSTALL_BLOB_SHA=6068fe4bd248c4ae4ff846b11a5ae0bd95a28dca
PANEL_INSTALL_URL="https://raw.githubusercontent.com/amirotin/telemt_panel/${PANEL_INSTALL_COMMIT}/install.sh"
''')

replace(telemt,
'''say(){ printf '%s\\n' "$*"; }; ok(){ printf '✓ %s\\n' "$*"; }; warn(){ printf '! %s\\n' "$*" >&2; }; die(){ printf '✗ %s\\n' "$*" >&2; exit 1; }

panel_domain(){''',
'''say(){ printf '%s\\n' "$*"; }; ok(){ printf '✓ %s\\n' "$*"; }; warn(){ printf '! %s\\n' "$*" >&2; }; die(){ printf '✗ %s\\n' "$*" >&2; exit 1; }

git_blob_sha(){
  local file="$1" size
  command -v sha1sum >/dev/null 2>&1 || return 1
  size="$(wc -c <"$file" | tr -d '[:space:]')"
  { printf 'blob %s\\000' "$size"; cat "$file"; } | sha1sum | awk '{print $1}'
}
download_git_blob_checked(){
  local url="$1" expected="$2" dst="$3" actual
  rm -f "$dst"
  curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 "$url" -o "$dst" || { rm -f "$dst"; return 1; }
  actual="$(git_blob_sha "$dst")" || { rm -f "$dst"; return 1; }
  [ "$actual" = "$expected" ] || { warn "Integrity check failed: git blob $actual != $expected ($url)"; rm -f "$dst"; return 1; }
  sh -n "$dst" || { rm -f "$dst"; return 1; }
  chmod 0700 "$dst"
}

panel_domain(){''')

replace(telemt,
'''load_state(){ MANAGED_TELEMT=0; MANAGED_PANEL=0; TELEMT_UNIT=""; TELEMT_API_PORT=""; TELEMT_CONFIG=""; [ -s "$TELEMT_STATE" ] && . "$TELEMT_STATE"; }
''',
'''load_state(){
  MANAGED_TELEMT=0; MANAGED_PANEL=0; TELEMT_UNIT=""; TELEMT_API_PORT=""; TELEMT_CONFIG=""
  [ -s "$TELEMT_STATE" ] || return 0
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      MANAGED_TELEMT|MANAGED_PANEL|TELEMT_UNIT|TELEMT_API_PORT|TELEMT_CONFIG) printf -v "$key" '%s' "$value" ;;
    esac
  done < "$TELEMT_STATE"
  [[ "$MANAGED_TELEMT" =~ ^[01]$ ]] || MANAGED_TELEMT=0
  [[ "$MANAGED_PANEL" =~ ^[01]$ ]] || MANAGED_PANEL=0
  [[ "$TELEMT_API_PORT" =~ ^[0-9]*$ ]] || TELEMT_API_PORT=""
}
''')

replace(telemt,
'''    tmp="$(mktemp)"; curl -fsSL "$TELEMT_INSTALL_URL" -o "$tmp"; $SUDO sh "$tmp" -l ru -d "$tlsdomain" -p "$port"; rm -f "$tmp"; open_port "$port"
''',
'''    tmp="$(mktemp)"; download_git_blob_checked "$TELEMT_INSTALL_URL" "$TELEMT_INSTALL_BLOB_SHA" "$tmp" || die "Telemt installer integrity check failed"
    $SUDO env VERSION="$TELEMT_VERSION" sh "$tmp" -l ru -d "$tlsdomain" -p "$port"; rm -f "$tmp"; open_port "$port"
''')

replace(telemt,
'''  if systemctl cat telemt-panel.service >/dev/null 2>&1 && [ -f "$PANEL_CONFIG" ]; then ok "Существующая Telemt Panel найдена — не переустанавливаю."; else tmp="$(mktemp)"; curl -fsSL "$PANEL_INSTALL_URL" -o "$tmp"; $SUDO bash "$tmp"; rm -f "$tmp"; managed_panel=1; fi
''',
'''  if systemctl cat telemt-panel.service >/dev/null 2>&1 && [ -f "$PANEL_CONFIG" ]; then
    ok "Существующая Telemt Panel найдена — не переустанавливаю."
  else
    tmp="$(mktemp)"; download_git_blob_checked "$PANEL_INSTALL_URL" "$PANEL_INSTALL_BLOB_SHA" "$tmp" || die "Telemt Panel installer integrity check failed"
    $SUDO sh "$tmp" install "$PANEL_VERSION"; rm -f "$tmp"; managed_panel=1
  fi
''')

print("supply-chain payload patch applied")
