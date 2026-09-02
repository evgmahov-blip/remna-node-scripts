#!/usr/bin/env python3
from pathlib import Path

p = Path('install-caddy-node-reality-stream.sh')
s = p.read_text()

def r(old, new, count=1):
    global s
    if old not in s:
        raise SystemExit(f'expected block missing: {old[:120]!r}')
    s = s.replace(old, new, count)

r('''REPO_RAW="https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/main"
INSTALL_DIR=/opt/remna-node-scripts
''','''REPO_REF=32bdefa2872aef9c59fd3af99ea106773a7e2530
REPO_RAW="https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/${REPO_REF}"
CORE_BLOB_SHA=a9074d627869935311669cf23f417d913b84a4e6
TELEMT_BLOB_SHA=51604bcdd1435f2870b3428ed81b46c8389fdb8c
PROTECTION_BLOB_SHA=9185f9723d959250a5ee766b0ff71e0a977a1982
REMNA_NODE_IMAGE="${REMNA_NODE_IMAGE:-remnawave/node:3.4.1}"
INSTALL_DIR=/opt/remna-node-scripts
''')

r('''download_checked(){
  local url="$1" dst="$2" tmp
  tmp="$(mktemp)"
  if curl -fsSL --connect-timeout 8 --max-time 30 "$url" -o "$tmp" && bash -n "$tmp"; then
    $SUDO install -m 0700 "$tmp" "$dst"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}
''','''git_blob_sha(){
  local file="$1" size
  command -v sha1sum >/dev/null 2>&1 || return 1
  size="$(wc -c <"$file" | tr -d '[:space:]')"
  { printf 'blob %s\\000' "$size"; cat "$file"; } | sha1sum | awk '{print $1}'
}

verified_script(){
  local file="$1" expected="$2" actual
  [ -s "$file" ] || return 1
  actual="$(git_blob_sha "$file")" || return 1
  [ "$actual" = "$expected" ] && bash -n "$file"
}

download_checked(){
  local url="$1" expected="$2" dst="$3" tmp actual
  tmp="$(mktemp)"
  if curl -fsSL --connect-timeout 8 --max-time 30 --retry 2 "$url" -o "$tmp"; then
    actual="$(git_blob_sha "$tmp" 2>/dev/null || true)"
    if [ "$actual" = "$expected" ] && bash -n "$tmp"; then
      $SUDO install -m 0700 "$tmp" "$dst"
      rm -f "$tmp"
      return 0
    fi
    warn "Проверка целостности не пройдена: $url (git blob ${actual:-unknown}, ожидался $expected)."
  fi
  rm -f "$tmp"
  return 1
}
''')

r('''  if download_checked "$REPO_RAW/install-caddy-node-reality-stream-core.sh" "$CORE"; then return 0; fi
  [ -s "$CORE" ] && bash -n "$CORE" && { warn "GitHub недоступен — использую проверенный локальный core."; return 0; }
''','''  if download_checked "$REPO_RAW/install-caddy-node-reality-stream-core.sh" "$CORE_BLOB_SHA" "$CORE"; then return 0; fi
  verified_script "$CORE" "$CORE_BLOB_SHA" && { warn "GitHub недоступен — использую локальный core с ожидаемым blob SHA."; return 0; }
''')
r('''  if download_checked "$REPO_RAW/telemt-manager.sh" "$TELEMT_HELPER"; then return 0; fi
  [ -s "$TELEMT_HELPER" ] && bash -n "$TELEMT_HELPER" && { warn "GitHub недоступен — использую локальный Telemt helper."; return 0; }
''','''  if download_checked "$REPO_RAW/telemt-manager.sh" "$TELEMT_BLOB_SHA" "$TELEMT_HELPER"; then return 0; fi
  verified_script "$TELEMT_HELPER" "$TELEMT_BLOB_SHA" && { warn "GitHub недоступен — использую локальный Telemt helper с ожидаемым blob SHA."; return 0; }
''')
r('''  if download_checked "$REPO_RAW/protection-manager.sh" "$PROTECTION_HELPER"; then return 0; fi
  [ -s "$PROTECTION_HELPER" ] && bash -n "$PROTECTION_HELPER" && { warn "GitHub недоступен — использую локальный protection helper."; return 0; }
''','''  if download_checked "$REPO_RAW/protection-manager.sh" "$PROTECTION_BLOB_SHA" "$PROTECTION_HELPER"; then return 0; fi
  verified_script "$PROTECTION_HELPER" "$PROTECTION_BLOB_SHA" && { warn "GitHub недоступен — использую локальный protection helper с ожидаемым blob SHA."; return 0; }
''')

# Pin existing legacy :latest compose only after the single-service safety gate.
r('''  tmp="$(mktemp)"
  awk '
    /^[[:space:]]*SECRET_KEY:[[:space:]]*/ {next}
    {print}
  ' "$compose" > "$tmp"

''','''  tmp="$(mktemp)"
  awk '
    /^[[:space:]]*SECRET_KEY:[[:space:]]*/ {next}
    {print}
  ' "$compose" > "$tmp"

  if grep -qE '^[[:space:]]*image:[[:space:]]*remnawave/node:latest[[:space:]]*$' "$tmp"; then
    sed -E "s#^([[:space:]]*image:[[:space:]]*)remnawave/node:latest[[:space:]]*$#\\1${REMNA_NODE_IMAGE}#" "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
    need_recreate=1
    ok "Remnawave Node image зафиксирован: $REMNA_NODE_IMAGE"
  fi

''')

# A truly read-only firewall check for diagnose: no helper download, no config creation.
r('''protection(){ ensure_protection_helper; "$PROTECTION_HELPER" "$@"; }

safe_diagnose(){''','''protection(){ ensure_protection_helper; "$PROTECTION_HELPER" "$@"; }

protection_node_api_readonly(){
  command -v iptables >/dev/null 2>&1 || return 1
  $SUDO iptables -C INPUT -j REMNA_GUARD >/dev/null 2>&1 || return 1
  $SUDO iptables -C REMNA_GUARD -p tcp --dport 2222 -j DROP >/dev/null 2>&1 || return 1
  $SUDO iptables -S REMNA_GUARD 2>/dev/null | grep -Eq -- '-p tcp .*--dport 2222 .* -j ACCEPT'
}

safe_diagnose(){''')
r('''  if protection check-node-api 2>/dev/null; then :; else
    echo '  ✗ TCP/2222 не защищён. В меню выбери «Защита ноды» → «Задать IP панели».'
  fi
''','''  if protection_node_api_readonly; then
    echo '  ✓ TCP/2222: REMNA_GUARD содержит allow + default DROP.'
  else
    echo '  ✗ TCP/2222 не защищён или защита не обнаружена. В меню выбери «Защита ноды» → «Задать IP панели».'
  fi
''')

p.write_text(s)
print('manager pin patch applied')
