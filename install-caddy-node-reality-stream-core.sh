#!/usr/bin/env bash
# ============================================================================
#  version: r9
#  install-caddy-node-reality-stream.sh — Remnawave Node + единый
#  VLESS XHTTP+REALITY inbound на внешнем TCP/443 и Caddy self-steal fallback.
#  До применения профиля Caddy держит :443. После старта rw-core Caddy
#  переводится на 127.0.0.1:8443, а REALITY target /dev/shm/nginx.sock
#  проходит через локальный L4 fallback-proxy к Caddy.
#
#  Запуск без аргументов открывает МЕНЮ. Также доступны подкоманды:
#    install | --auto   полная установка (нода по SECRET_KEY + Caddy)
#    front-only         только фронт Caddy (ноду поднять отдельно)
#    reinstall          снос всего локального + установка заново
#    path               сгенерировать/показать туннель-путь
#    path-set PATH      изменить XHTTP-путь в Caddy-конфигах
#    summary            «что и куда вставлять» для Config Profile / Host
#    diagnose | diag    глубокая диагностика (симптом → причина → фикс)
#    status             статус сервисов (caddy / remnanode / порты)
#    repair | fix       исправить сайт и конфликт Caddy/Reality на текущей ноде
#    stream             установить/обновить стрим-сайт
#    reality-prepare    подготовить XHTTP+REALITY JSON и локальный Caddy:8443
#    reality-enable     переключить Caddy на 127.0.0.1:8443 и ждать rw-core:443
#    reality-disable    вернуть публичный Caddy:443 после удаления Reality inbound
#    reality-info       показать пути к подготовленным файлам без вывода ключей
#    clean | uninstall  снести ноду и конфиг Caddy
#    menu               показать меню (по умолчанию)
#    -h | --help        эта справка
#
#  Запускается через проверяемый launcher install-caddy-node-reality-stream.sh.
#
#  Неинтерактивно:
#    EMAIL=you@mail.com DOMAIN=node.example.net SECRET_KEY=... \
#      REMNA_NONINTERACTIVE=1 bash $0 --auto
# ============================================================================
set -Eeuo pipefail

# ── Порты (фиксированные для метода) ─────────────────────────────────────────
NODE_PORT=2222          # API-порт ноды Remnawave (mTLS)
REALITY_PORT=443        # единый VLESS XHTTP + REALITY inbound
CADDY_LOCAL_PORT=8443   # локальный HTTPS Caddy за REALITY self-steal
REALITY_SOCKET_DIR=/dev/shm/remna-reality
REALITY_SOCKET_TARGET=/dev/shm/nginx.sock
FALLBACK_SERVICE=remna-reality-fallback.service
FALLBACK_UNIT=/etc/systemd/system/$FALLBACK_SERVICE
CADDYFILE=/etc/caddy/Caddyfile
CADDY_PUBLIC=/etc/caddy/Caddyfile.public
CADDY_REALITY=/etc/caddy/Caddyfile.reality
NODE_DIR=/opt/remnanode
REALITY_DIR=/opt/remnanode/reality
REALITY_ENV=$REALITY_DIR/reality.env
PROFILE_INBOUND=$REALITY_DIR/xhttp-reality-inbound.json
PROFILE_INBOUNDS=$REALITY_DIR/inbounds-ready.json
FALLBACK_CONFIG=$REALITY_DIR/haproxy.cfg
SCRIPT_INSTALL_DIR=/opt/remna-node-scripts
MANAGER_PATH=$SCRIPT_INSTALL_DIR/install-caddy-node-reality-stream.sh
CORE_SELF_PATH=$SCRIPT_INSTALL_DIR/install-caddy-node-reality-stream-core.sh
CADDY_GUARD=$SCRIPT_INSTALL_DIR/caddy-resilient-start.sh
PROFILE_WATCH_SERVICE=remna-profile-wait.service  # legacy: удаляется при обновлении/сносе
PROFILE_WATCH_UNIT=/etc/systemd/system/$PROFILE_WATCH_SERVICE
WEBROOT=/var/www/mstream
STREAM_SITE_URL="${STREAM_SITE_URL:-}"
STREAM_SITE_ARCHIVE="${STREAM_SITE_ARCHIVE:-}"
STREAM_SITE_SHA256="${STREAM_SITE_SHA256:-}"
REMNA_NODE_IMAGE="${REMNA_NODE_IMAGE:-remnawave/node:3.4.1}"
DOCKER_INSTALL_COMMIT=42dcae692436f34526524ed46d3b32885c9355f5
DOCKER_INSTALL_BLOB_SHA=c67c0e799b42c0435949a3f83785749480d5f14d
DOCKER_INSTALL_URL="https://raw.githubusercontent.com/docker/docker-install/${DOCKER_INSTALL_COMMIT}/install.sh"

# ── Цвета (гасим при не-TTY: pipe/CI) ────────────────────────────────────────
if [ -t 1 ]; then
  N=$'\e[0m'; DIM=$'\e[2m'; B=$'\e[1m'
  R=$'\e[91m'; G=$'\e[92m'; Y=$'\e[93m'; BL=$'\e[94m'; C=$'\e[96m'; M=$'\e[95m'
else
  N=""; DIM=""; B=""; R=""; G=""; Y=""; BL=""; C=""; M=""
fi
say()  { printf '%b\n' "$*"; }
log()  { printf '%b[*]%b %s\n' "$BL" "$N" "$*"; }
ok()   { printf '%b✓%b %s\n'  "$G"  "$N" "$*"; }
warn() { printf '%b!%b %s\n'  "$Y"  "$N" "$*"; }
die()  { printf '%b✗ %s%b\n'  "$R"  "$*" "$N" >&2; exit 1; }
line() { printf '%b────────────────────────────────────────────────────────────%b\n' "$DIM" "$N"; }
MENU_BACK_RC=20
is_menu_back() {
  case "${1:-}" in 0|q|Q|back|BACK|Back|назад|Назад|НАЗАД) return 0 ;; *) return 1 ;; esac
}
back_to_menu() {
  warn "Операция отменена — возвращаюсь в меню."
  exit "$MENU_BACK_RC"
}

banner() {
  echo
  printf '  %b%b────────────────────────────────────────────────────────────%b\n' "$B" "$C" "$N"
  printf '  %b%b🌐 REMNA NODE%b  %b·%b  %bXHTTP + REALITY :443%b  %b·%b  %bSELF-STEAL%b\n' \
    "$B" "$C" "$N" "$DIM" "$N" "$B" "$N" "$DIM" "$N" "$M" "$N"
  printf '  %bОдин inbound: VLESS XHTTP + REALITY на 0.0.0.0:443 · Caddy fallback :8443%b\n' "$DIM" "$N"
  printf '  %b%b────────────────────────────────────────────────────────────%b\n' "$B" "$C" "$N"
  echo
}

# ── Глобальный ERR-trap: ни одно падение set -e не проходит молча ────────────
err_trap() {
  local rc=$1 ln=$2 cmd=$3
  printf '\n%b✗ Прервано: строка %s, код %s%b\n' "$R" "$ln" "$rc" >&2
  printf '%b  команда: %s%b\n' "$R" "$cmd" "$N" >&2
  printf '%b  диагностика: caddy validate --config %s ; docker logs --tail 40 remnanode ; journalctl -u caddy -e%b\n' "$Y" "$CADDYFILE" "$N" >&2
  exit "$rc"
}
trap 'err_trap $? $LINENO "$BASH_COMMAND"' ERR

# ── sudo / окружение ─────────────────────────────────────────────────────────
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
command -v apt-get >/dev/null 2>&1 || die "Нужен Ubuntu/Debian (apt-get не найден)."
APT_LOCK_TIMEOUT=${APT_LOCK_TIMEOUT:-300}
apt_get(){ $SUDO apt-get -o DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT" "$@"; }

persist_self() {
  local current
  current="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  [ "$current" = "$CORE_SELF_PATH" ] && [ -s "$CORE_SELF_PATH" ] && return 0
  case "$current" in /dev/fd/*|/proc/*/fd/*) return 0 ;; esac
  [ -f "$current" ] && [ -s "$current" ] || return 0
  $SUDO install -d -o root -g root -m 0755 "$SCRIPT_INSTALL_DIR"
  $SUDO install -o root -g root -m 0700 "$current" "$CORE_SELF_PATH"
  ok "Core сохранён → $CORE_SELF_PATH"
}

git_blob_sha() {
  local file="$1" size
  command -v sha1sum >/dev/null 2>&1 || return 1
  size="$(wc -c <"$file" | tr -d '[:space:]')"
  { printf 'blob %s\000' "$size"; cat "$file"; } | sha1sum | awk '{print $1}'
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
  export DEBIAN_FRONTEND=noninteractive
  local missing=0 cmd
  for cmd in curl openssl ss shuf tar awk sed grep sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || missing=1
  done
  [ "$missing" -eq 0 ] && [ -s /etc/ssl/certs/ca-certificates.crt ] && return 0
  log "Устанавливаю базовые зависимости..."
  apt_get update -y
  apt_get install -y curl ca-certificates openssl iproute2 coreutils tar gawk sed grep
}

# ── Ввод: env в приоритете; интерактив читаем с /dev/tty (работает и под curl|bash)
TTY=/dev/tty; { [ -r /dev/tty ] && [ -w /dev/tty ]; } || TTY=/dev/stdin
if [ -t 0 ] || [ "$TTY" = /dev/tty ]; then INTERACTIVE=1; else INTERACTIVE=0; fi
_ENV_EMAIL="${EMAIL:-}"; _ENV_DOMAIN="${DOMAIN:-}"; _ENV_SECRET="${SECRET_KEY:-}"
EMAIL="${EMAIL:-}"; DOMAIN="${DOMAIN:-}"; SECRET_KEY="${SECRET_KEY:-}"
TUNNEL_PATH="${TUNNEL_PATH:-}"

# ── Генерация случайного туннель-пути (тот же алгоритм, что в веб-конфигураторе)
WORDS=(api cdn static media stream assets data content core edge node live cache gateway service push pull sync fetch upload chunk segment frame track session blob object store queue relay proxy hub channel feed source origin mirror vault bucket shard packet tile manifest playlist thumb preview render worker signal beacon pixel event report metric)
VERSIONS=(v1 v2 v3 v4 v5 v6 api2 r2 g2 beta stable latest)
EXTS=(php ts)
gen_path() {
  local pool; pool=( $(printf '%s\n' "${WORDS[@]}" | shuf) )
  local dirs=$(( RANDOM % 3 + 1 )) parts=() idx=0 i
  for (( i=0; i<dirs; i++ )); do parts+=("${pool[idx]}"); idx=$(( idx + 1 )); done
  if (( RANDOM % 3 != 0 )); then parts[$(( RANDOM % ${#parts[@]} ))]="${VERSIONS[$(( RANDOM % ${#VERSIONS[@]} ))]}"; fi
  printf '/%s/%s.%s\n' "$(IFS=/; echo "${parts[*]}")" "${pool[idx]}" "${EXTS[$(( RANDOM % ${#EXTS[@]} ))]}"
}

normalize_path() {
  local p="${1:-}"
  p="$(printf '%s' "$p" | tr -d '\r\n\t')"
  p="${p#http://}"; p="${p#https://}"
  [ -n "$p" ] || return 1
  case "$p" in /*) : ;; *) p="/$p" ;; esac
  while [ "$p" != "/" ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  [ "$p" != "/" ] || die "XHTTP-путь не может быть корнем /."
  printf '%s' "$p" | grep -Eq '^/[A-Za-z0-9._~/-]+$' || die "XHTTP-путь содержит недопустимые символы. Разрешены буквы, цифры, / . _ - ~"
  case "$p" in *'//'*) die "XHTTP-путь не должен содержать //." ;; esac
  case "/$p/" in *'/../'*|*'/./'*) die "XHTTP-путь не должен содержать . или .. как сегмент." ;; esac
  printf '%s\n' "$p"
}

choose_tunnel_path() {
  local entered=""
  if [ -n "${TUNNEL_PATH:-}" ]; then
    TUNNEL_PATH="$(normalize_path "$TUNNEL_PATH")"
    return 0
  fi
  if [ "$INTERACTIVE" = 1 ]; then
    printf 'XHTTP-путь (Enter = сгенерировать случайный, 0 = назад): '
    read -r entered <"$TTY" || true
    is_menu_back "$entered" && back_to_menu
  fi
  if [ -n "$entered" ]; then
    TUNNEL_PATH="$(normalize_path "$entered")"
  else
    TUNNEL_PATH="$(gen_path)"
  fi
}

# ── Санитизация SECRET_KEY: пробелы, префикс SECRET_KEY=/SSL_CERT=, кавычки ──
sanitize_key() {
  SECRET_KEY="$(printf '%s' "${SECRET_KEY:-}" | tr -d '[:space:]')"
  SECRET_KEY="${SECRET_KEY#SECRET_KEY=}"; SECRET_KEY="${SECRET_KEY#SSL_CERT=}"
  SECRET_KEY="${SECRET_KEY%\"}"; SECRET_KEY="${SECRET_KEY#\"}"
  SECRET_KEY="${SECRET_KEY%\'}"; SECRET_KEY="${SECRET_KEY#\'}"
  SECRET_KEY="${SECRET_KEY#SECRET_KEY=}"; SECRET_KEY="${SECRET_KEY#SSL_CERT=}"  # повтор на случай «"SECRET_KEY=…"»
}

# ── Текущий туннель-путь из Caddyfile (строка @tunnel «path /...», НЕ handle_path /health) ──
current_path() {
  [ -f "$CADDYFILE" ] || return 0
  awk '/^[[:space:]]*path \//{print $2; exit}' "$CADDYFILE" 2>/dev/null | sed 's/\*$//' || true
}

# ── Сбор параметров (спрашиваем только незаданное через env) ─────────────────
collect_params() {
  local need_node="${1:-ask}"   # ask|node|front
  if [ -z "$EMAIL" ]; then
    [ "$INTERACTIVE" = 1 ] || die "EMAIL не задан. Передай через env: EMAIL=you@mail.com bash $0 --auto"
    printf 'Email (для Let'\''s Encrypt, 0 = назад): '
    read -r EMAIL <"$TTY" || true
    is_menu_back "$EMAIL" && back_to_menu
  fi
  while ! printf '%s' "$EMAIL" | grep -q '@'; do
    [ "$INTERACTIVE" = 1 ] || die "EMAIL некорректен/не задан (env: EMAIL=...)."
    printf '  Некорректный email. Повтори (0 = назад): '
    read -r EMAIL <"$TTY" || true
    is_menu_back "$EMAIL" && back_to_menu
  done

  if [ -z "$DOMAIN" ]; then
    [ "$INTERACTIVE" = 1 ] || die "DOMAIN не задан. Передай через env: DOMAIN=node.example.net bash $0 --auto"
    printf 'Домен ноды (например finka.example.ru, 0 = назад): '
    read -r DOMAIN <"$TTY" || true
    is_menu_back "$DOMAIN" && back_to_menu
  fi
  DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%/}"
  DOMAIN="$(printf '%s' "$DOMAIN" | tr -d '[:space:]')"
  [ -n "$DOMAIN" ] || die "Домен пустой."

  if [ "$need_node" != "front" ] && [ -z "$SECRET_KEY" ]; then
    printf 'Поставить ноду здесь же? Вставь SECRET_KEY из панели Remnawave (Enter = только фронт, 0 = назад).\n'
    printf '%b  ввод СКРЫТ — символы не отображаются, это нормально. Вставляй ТОЛЬКО значение ключа,%b\n' "$DIM" "$N"
    printf '%b  без «SECRET_KEY=» и без кавычек.%b\n' "$DIM" "$N"
    printf 'SECRET_KEY: '
    read -rs SECRET_KEY <"$TTY" || true; echo
    is_menu_back "$SECRET_KEY" && back_to_menu
  fi
  sanitize_key
  if [ -n "$SECRET_KEY" ]; then
    ok "Ключ принят: ${#SECRET_KEY} символов. Значение не выводится."
    [ "${#SECRET_KEY}" -ge 40 ] || warn "Ключ короткий (${#SECRET_KEY} симв.) — возможно, вставился обрезанным."
  fi
  choose_tunnel_path
  : # стрим-сайт фиксированный; каталог случайных заглушек не используется
}

# ── Установка ноды Remnanode (Docker) ────────────────────────────────────────
install_node() {
  [ -n "$SECRET_KEY" ] || { warn "SECRET_KEY пуст — ноду не ставлю (только фронт)."; return 0; }
  log "Docker + Remnanode..."
  export DEBIAN_FRONTEND=noninteractive
  if ! command -v curl >/dev/null 2>&1 || [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
    apt_get update -y
    apt_get install -y curl ca-certificates
  fi
  if ! command -v docker >/dev/null 2>&1; then
    log "Ставлю Docker из зафиксированного официального installer commit..."
    download_git_blob_checked "$DOCKER_INSTALL_URL" "$DOCKER_INSTALL_BLOB_SHA" /tmp/get-docker.sh \
      || die "Не удалось скачать/проверить Docker installer."
    $SUDO sh /tmp/get-docker.sh
    $SUDO rm -f /tmp/get-docker.sh
  fi
  command -v docker >/dev/null 2>&1 || die "Docker не установлен."
  $SUDO docker compose version >/dev/null 2>&1 || die "Docker Compose plugin не найден."
  $SUDO install -d -o root -g root -m 0700 "$NODE_DIR" "$REALITY_DIR"
  $SUDO install -d -o root -g root -m 0755 "$REALITY_SOCKET_DIR"
  local compose_tmp; compose_tmp="$(mktemp)"
  cat >"$compose_tmp" <<NODE_EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ${REMNA_NODE_IMAGE}
    network_mode: host
    restart: always
    volumes:
      - ${REALITY_SOCKET_DIR}:/dev/shm
    environment:
      NODE_PORT: "${NODE_PORT}"
      SECRET_KEY: "${SECRET_KEY}"
NODE_EOF
  $SUDO install -o root -g root -m 0600 "$compose_tmp" "$NODE_DIR/docker-compose.yml"
  rm -f "$compose_tmp"
  ( cd "$NODE_DIR" && $SUDO docker compose pull && $SUDO docker compose up -d ) || die "Не удалось поднять Remnanode."
  sleep 5
  if $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'remnanode'; then
    ok "Remnanode запущен → $NODE_DIR"
  else
    warn "Remnanode не удержался в запущенном состоянии."
    $SUDO docker logs --tail 40 remnanode 2>&1 |       sed -E 's/(token=)[^&[:space:]]+/\1<REDACTED>/Ig; s/(SECRET_KEY[=:][[:space:]]*)[^[:space:]]+/\1<REDACTED>/Ig' |       sed 's/^/    /' || true
    die "Remnanode не запущен. Проверь SECRET_KEY и доступность панели."
  fi
  if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -qi 'Status: active'; then
    $SUDO ufw allow "${NODE_PORT}/tcp" >/dev/null 2>&1 || true
  fi
  warn "TCP/${NODE_PORT} должен быть доступен серверу панели Remnawave."
}

# ── Установка Caddy (идемпотентно) ───────────────────────────────────────────
install_caddy() {
  if command -v caddy >/dev/null 2>&1; then ok "Caddy уже установлен: $(caddy version 2>/dev/null | head -1)"; return 0; fi
  log "Установка Caddy из репозитория Cloudsmith..."
  export DEBIAN_FRONTEND=noninteractive
  apt_get update -y
  apt_get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | $SUDO gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | $SUDO tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt_get update -y
  apt_get install -y caddy
  ok "Caddy установлен: $(caddy version 2>/dev/null | head -1)"
}

# ── Caddyfile: публичный режим до включения REALITY ───────────────────────────
write_caddyfile() {
  log "Генерация публичного Caddyfile (путь XHTTP: ${G}${TUNNEL_PATH}${N})..."
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<'CADDY_EOF'
{
  email __EMAIL__
  servers {
    protocols h1 h2
    max_header_size 65536
  }
  auto_https disable_redirects
  log default {
    level ERROR
  }
}

__DOMAIN__ {
  tls {
    protocols tls1.2 tls1.3
  }

  header {
    -Server
    Cache-Control "no-store,no-cache,must-revalidate"
    Surrogate-Control "no-store"
    Pragma "no-cache"
  }

  handle /health* {
    respond 404
  }


  handle {
    root * __WEBROOT__
    try_files {path} /index.html
    file_server
  }
}
CADDY_EOF
  render_caddy_template "$tmp"
  $SUDO install -o root -g root -m 0644 "$tmp" "$CADDYFILE"
  $SUDO cp -a "$CADDYFILE" "$CADDY_PUBLIC"
  rm -f "$tmp"
  ok "Публичный Caddyfile → $CADDYFILE"
}

render_caddy_template() {
  local file="$1" se sd sp sw
  se="$(printf '%s' "$EMAIL"       | sed 's/[|&\\]/\\&/g')"
  sd="$(printf '%s' "$DOMAIN"      | sed 's/[|&\\]/\\&/g')"
  sp="$(printf '%s' "$TUNNEL_PATH" | sed 's/[|&\\]/\\&/g')"
  sw="$(printf '%s' "$WEBROOT"     | sed 's/[|&\\]/\\&/g')"
  sed -i "s|__EMAIL__|${se}|g; s|__DOMAIN__|${sd}|g; s|__PATH__|${sp}|g; s|__WEBROOT__|${sw}|g; s|__CADDY_LOCAL__|${CADDY_LOCAL_PORT}|g" "$file"
}

write_caddyfile_reality() {
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<'CADDY_REALITY_EOF'
{
  email __EMAIL__
  https_port __CADDY_LOCAL__
  default_bind 127.0.0.1
  auto_https disable_redirects
  log default {
    level ERROR
  }
  servers 127.0.0.1:__CADDY_LOCAL__ {
    protocols h1 h2
    max_header_size 65536
  }
}

__DOMAIN__ {
  bind 127.0.0.1
  tls {
    protocols tls1.2 tls1.3
    issuer acme {
      disable_http_challenge
    }
  }

  header {
    -Server
    Cache-Control "no-store,no-cache,must-revalidate"
    Surrogate-Control "no-store"
    Pragma "no-cache"
  }

  handle /health* {
    respond 404
  }


  handle {
    root * __WEBROOT__
    try_files {path} /index.html
    file_server
  }
}
CADDY_REALITY_EOF
  render_caddy_template "$tmp"
  $SUDO caddy fmt --overwrite "$tmp" >/dev/null 2>&1 || true
  $SUDO caddy validate --config "$tmp" --adapter caddyfile || die "Будущий Caddyfile REALITY не прошёл проверку."
  $SUDO install -o root -g root -m 0644 "$tmp" "$CADDY_REALITY"
  rm -f "$tmp"
  ok "Локальный Caddyfile REALITY → $CADDY_REALITY"
}

install_reality_socket_proxy() {
  command -v haproxy >/dev/null 2>&1 || {
    apt_get update -y
    apt_get install -y haproxy
  }
  command -v haproxy >/dev/null 2>&1 || die "haproxy не установлен."

  $SUDO install -d -o root -g root -m 0700 "$REALITY_DIR"
  $SUDO install -d -o root -g root -m 0755 "$REALITY_SOCKET_DIR"

  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<EOF
global
  log stdout format raw local0

defaults
  log global
  mode tcp
  timeout connect 5s
  timeout client 300s
  timeout server 300s

frontend reality_selfsteal
  bind $REALITY_SOCKET_TARGET accept-proxy mode 660
  default_backend caddy_tls

backend caddy_tls
  server caddy 127.0.0.1:${CADDY_LOCAL_PORT}
EOF
  $SUDO haproxy -c -f "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "HAProxy config для self-steal невалиден."; }
  $SUDO install -o root -g root -m 0600 "$tmp" "$FALLBACK_CONFIG"
  rm -f "$tmp"

  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
[Unit]
Description=Remna REALITY self-steal fallback socket
After=network.target

[Service]
Type=simple
ExecStartPre=/usr/bin/install -d -o root -g root -m 0755 $REALITY_SOCKET_DIR
ExecStartPre=-/usr/bin/rm -f $REALITY_SOCKET_TARGET
ExecStart=/usr/sbin/haproxy -W -db -f $FALLBACK_CONFIG
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF
  $SUDO install -o root -g root -m 0644 "$tmp" "$FALLBACK_UNIT"
  rm -f "$tmp"
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now "$FALLBACK_SERVICE" >/dev/null || die "Не удалось запустить $FALLBACK_SERVICE."

  local i
  for i in $(seq 1 20); do
    [ -S "$REALITY_SOCKET_DIR/nginx.sock" ] && break
    sleep 1
  done
  [ -S "$REALITY_SOCKET_DIR/nginx.sock" ] || {
    $SUDO journalctl -u "$FALLBACK_SERVICE" -n 50 --no-pager 2>/dev/null || true
    die "Fallback socket не создан: $REALITY_SOCKET_DIR/nginx.sock"
  }

  if $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
    $SUDO docker exec remnanode test -S "$REALITY_SOCKET_TARGET" 2>/dev/null ||
      warn "В remnanode пока не виден $REALITY_SOCKET_TARGET; compose будет пересоздан с shared /dev/shm mount."
  fi
  ok "REALITY self-steal socket готов: $REALITY_SOCKET_TARGET → Caddy 127.0.0.1:${CADDY_LOCAL_PORT}"
}
fix_site_permissions() {
  [ -d "$WEBROOT" ] || return 0
  $SUDO chmod 755 /var /var/www "$WEBROOT" 2>/dev/null || true
  $SUDO find "$WEBROOT" -type d -exec chmod 755 {} +
  $SUDO find "$WEBROOT" -type f -exec chmod 644 {} +
}

# ── Маскировочный сайт: встроенный или явно закреплённый оператором ───────────
sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

verify_sha256() {
  local file="$1" expected="$2" actual
  [ -n "$expected" ] || return 1
  actual="$(sha256_file "$file")"
  [ "$actual" = "$expected" ] || {
    warn "SHA-256 не совпал: $actual != $expected"
    return 1
  }
}

install_builtin_stream_site() {
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="robots" content="noindex,nofollow">
  <title>Media Stream</title>
  <style>
    body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0d1117;color:#e6edf3;font:16px system-ui,-apple-system,Segoe UI,sans-serif}
    main{max-width:42rem;padding:3rem;text-align:center}
    h1{font-size:2rem;margin:0 0 1rem}p{color:#9da7b3;line-height:1.6}
    .dot{display:inline-block;width:.65rem;height:.65rem;border-radius:50%;background:#3fb950;margin-right:.5rem}
  </style>
</head>
<body><main><h1><span class="dot"></span>Media service</h1><p>Streaming endpoint is online.</p></main></body>
</html>
HTML
  $SUDO find "$WEBROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  $SUDO install -o root -g root -m 0644 "$tmp" "$WEBROOT/index.html"
  rm -f "$tmp"
  fix_site_permissions
  ok "Установлена встроенная статическая заглушка без внешних JS/CSS → $WEBROOT"
}

install_stream_site() {
  $SUDO mkdir -p "$WEBROOT"

  if [ -n "$STREAM_SITE_ARCHIVE" ]; then
    local archive="$STREAM_SITE_ARCHIVE" tmpa="" tmpd idx
    tmpd="$(mktemp -d)"
    if printf '%s' "$archive" | grep -qE '^https://'; then
      [ -n "$STREAM_SITE_SHA256" ] || die "Для удалённого STREAM_SITE_ARCHIVE обязателен STREAM_SITE_SHA256."
      tmpa="$(mktemp)"
      curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 --retry 2 "$archive" -o "$tmpa" ||
        die "Не удалось скачать STREAM_SITE_ARCHIVE."
      verify_sha256 "$tmpa" "$STREAM_SITE_SHA256" || die "Проверка STREAM_SITE_ARCHIVE не пройдена."
      archive="$tmpa"
    elif [ -n "$STREAM_SITE_SHA256" ]; then
      verify_sha256 "$archive" "$STREAM_SITE_SHA256" || die "Проверка локального STREAM_SITE_ARCHIVE не пройдена."
    fi
    [ -f "$archive" ] || die "Архив маскировочного сайта не найден: $archive"
    if tar -tf "$archive" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
      die "Архив содержит небезопасные абсолютные/parent paths."
    fi
    tar --no-same-owner --no-same-permissions -xf "$archive" -C "$tmpd" || die "Не удалось распаковать архив маскировочного сайта."
    if find "$tmpd" -type l -print -quit | grep -q .; then
      rm -rf "$tmpd"; [ -z "$tmpa" ] || rm -f "$tmpa"
      die "Архив содержит symlink; такие архивы запрещены."
    fi
    idx="$(find "$tmpd" -type f -name index.html -print -quit)"
    [ -n "$idx" ] || die "В архиве нет index.html."
    $SUDO find "$WEBROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    $SUDO cp -a "$(dirname "$idx")"/. "$WEBROOT"/
    rm -rf "$tmpd"; [ -z "$tmpa" ] || rm -f "$tmpa"
    fix_site_permissions
    ok "Маскировочный сайт установлен из проверенного архива → $WEBROOT"
    return 0
  fi

  if [ -s "$WEBROOT/index.html" ] && [ "${FORCE_STREAM_REFRESH:-0}" != 1 ]; then
    fix_site_permissions
    ok "Маскировочный сайт уже существует → $WEBROOT (не перезаписываю)"
    return 0
  fi

  if [ -n "$STREAM_SITE_URL" ]; then
    local tmp
    [ -n "$STREAM_SITE_SHA256" ] || die "Для удалённого STREAM_SITE_URL обязателен STREAM_SITE_SHA256; без хеша удалённый HTML не исполняется."
    printf '%s' "$STREAM_SITE_URL" | grep -qE '^https://' || die "STREAM_SITE_URL должен использовать https://"
    tmp="$(mktemp)"
    curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 30 --retry 2 "$STREAM_SITE_URL" -o "$tmp" ||
      die "Не удалось скачать STREAM_SITE_URL."
    verify_sha256 "$tmp" "$STREAM_SITE_SHA256" || { rm -f "$tmp"; die "Проверка STREAM_SITE_URL не пройдена."; }
    grep -Eqi '<html|<!doctype|<head|<body' "$tmp" || { rm -f "$tmp"; die "STREAM_SITE_URL не похож на HTML."; }
    $SUDO find "$WEBROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    $SUDO install -o root -g root -m 0644 "$tmp" "$WEBROOT/index.html"
    rm -f "$tmp"
    fix_site_permissions
    ok "Маскировочный HTML установлен из HTTPS-источника с закреплённым SHA-256 → $WEBROOT"
    return 0
  fi

  install_builtin_stream_site
}

# Совместимость с исходным run_install/cmd_decoy.
install_decoy() { install_stream_site; }
install_decoy_builtin() { install_builtin_stream_site; }

# ── Валидация + запуск Caddy ─────────────────────────────────────────────────
caddy_prepare_for_owner() {
  if [ -x "$CADDY_GUARD" ]; then
    CADDYFILE="$CADDYFILE" CADDY_PUBLIC="$CADDY_PUBLIC" CADDY_REALITY="$CADDY_REALITY" \
      CADDY_LOCAL_PORT="$CADDY_LOCAL_PORT" $SUDO "$CADDY_GUARD" prepare
    return $?
  fi
  command -v ss >/dev/null 2>&1 || return 0
  command -v caddy >/dev/null 2>&1 || return 0
  if rw_core_on_443; then
    [ -s "$CADDY_REALITY" ] || return 0
    $SUDO caddy validate --config "$CADDY_REALITY" --adapter caddyfile >/dev/null 2>&1 || return 1
    $SUDO install -o root -g root -m 0644 "$CADDY_REALITY" "$CADDYFILE"
  else
    [ -s "$CADDY_PUBLIC" ] || return 0
    $SUDO caddy validate --config "$CADDY_PUBLIC" --adapter caddyfile >/dev/null 2>&1 || return 1
    $SUDO install -o root -g root -m 0644 "$CADDY_PUBLIC" "$CADDYFILE"
  fi
}

restart_caddy_for_owner() {
  caddy_prepare_for_owner
  $SUDO systemctl restart caddy
}

reload_or_restart_caddy_for_owner() {
  caddy_prepare_for_owner || true
  $SUDO systemctl reload caddy >/dev/null 2>&1 || restart_caddy_for_owner
}

start_caddy() {
  log "Проверка и запуск Caddy..."
  caddy_prepare_for_owner
  $SUDO caddy fmt --overwrite "$CADDYFILE" >/dev/null 2>&1 || true
  $SUDO caddy validate --config "$CADDYFILE" --adapter caddyfile || die "Caddyfile не прошёл валидацию."
  $SUDO systemctl enable caddy >/dev/null 2>&1 || true
  if ! restart_caddy_for_owner; then
    $SUDO journalctl -u caddy -n 40 --no-pager 2>/dev/null || true
    die "Caddy не запустился."
  fi
  sleep 1
  $SUDO systemctl is-active --quiet caddy || die "Caddy не активен после запуска."
  ok "Caddy активен и запущен"
}

site_code() {
  local port="$1" url code
  if [ "$port" = 443 ]; then url="https://${DOMAIN}/"; else url="https://${DOMAIN}:${port}/"; fi

  # This is a LOCAL health check. Never send it through HTTP(S)_PROXY.
  code="$(curl -ksS --noproxy '*' --connect-timeout 3 --max-time 8 \
    --resolve "${DOMAIN}:${port}:127.0.0.1" \
    -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
  if [ -n "$code" ] && [ "$code" != 000 ]; then
    printf '%s' "$code"
    return 0
  fi

  # Public Caddy may be IPv6-only on some hosts; try loopback v6 as fallback.
  if [ "$port" = 443 ]; then
    code="$(curl -gksS --noproxy '*' --connect-timeout 3 --max-time 8 \
      --resolve "${DOMAIN}:${port}:[::1]" \
      -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
  fi
  printf '%s' "${code:-000}"
}

site_probe_diagnostics() {
  local port="$1"
  warn "Локальная HTTPS-проверка не прошла. Диагностика без изменения конфигурации:"
  printf '  caddy service : %s\n' "$($SUDO systemctl is-active caddy 2>/dev/null || echo unknown)"
  printf '  listeners     :\n'
  ss -lntp 2>/dev/null | grep -E ":${port}[[:space:]]|127\.0\.0\.1:${CADDY_LOCAL_PORT}[[:space:]]|:${NODE_PORT}[[:space:]]" | sed 's/^/    /' || echo '    (нет ожидаемых listener)'
  printf '  caddy journal :\n'
  $SUDO journalctl -u caddy -n 20 --no-pager 2>/dev/null | tail -20 | sed 's/^/    /' || true
}

check_site_port() {
  local port="$1" attempts="${2:-8}" code="" i
  fix_site_permissions
  for i in $(seq 1 "$attempts"); do
    code="$(site_code "$port")"
    if [ "$code" = 200 ]; then
      ok "Стрим-сайт отвечает HTTP 200 на порту ${port}."
      return 0
    fi
    if [ "$code" = 403 ]; then
      warn "Caddy вернул 403; исправляю права стрим-сайта."
      fix_site_permissions
      reload_or_restart_caddy_for_owner >/dev/null 2>&1 || true
    fi
    sleep 3
  done
  warn "Стрим-сайт не прошёл проверку на порту ${port}: HTTP ${code:-нет ответа}."
  site_probe_diagnostics "$port"
  return 1
}

verify_site_port() {
  local port="$1"
  check_site_port "$port" 8 || die "Стрим-сайт не отвечает HTTP 200 на порту ${port}."
}

listener_is() {
  local port="$1" process="$2" bind_re="${3:-}"
  local lines
  lines="$(ss -lntp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" || true)"
  [ -n "$lines" ] || return 1
  printf '%s\n' "$lines" | grep -q "$process" || return 1
  [ -z "$bind_re" ] || printf '%s\n' "$lines" | grep -Eq "$bind_re"
}

rw_core_on_443() {
  listener_is "$REALITY_PORT" 'rw-core'
}

caddy_public_443() {
  listener_is "$REALITY_PORT" 'caddy'
}

caddy_local_8443() {
  listener_is "$CADDY_LOCAL_PORT" 'caddy' '127\.0\.0\.1:8443'
}

reality_front_ready() {
  rw_core_on_443 && caddy_local_8443
}

final_topology_ready() {
  reality_front_ready &&
  listener_is "$NODE_PORT" 'rw-node' &&
  [ -S "$REALITY_SOCKET_DIR/nginx.sock" ] &&
  $SUDO docker exec remnanode test -S "$REALITY_SOCKET_TARGET" >/dev/null 2>&1
}

show_topology() {
  ss -lntp 2>/dev/null | grep -E ":(${NODE_PORT}|${REALITY_PORT}|${CADDY_LOCAL_PORT})[[:space:]]" || true
  printf '  self-steal socket: %s\n' "$([ -S "$REALITY_SOCKET_DIR/nginx.sock" ] && echo ready || echo missing)"
}

node_has_443_conflict() {
  command -v docker >/dev/null 2>&1 || return 1
  $SUDO docker logs --since 10m remnanode 2>&1 | tr -d '\000' | \
    grep -aEq 'failed to listen TCP on 443.*address already in use|listen tcp 0\.0\.0\.0:443: bind: address already in use'
}

restart_remnanode_if_present() {
  command -v docker >/dev/null 2>&1 || return 0
  $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'remnanode' || return 0
  $SUDO docker restart remnanode >/dev/null 2>&1 || true
}

wait_for_rw_core_443() {
  local timeout="${1:-35}" i
  for i in $(seq 1 "$timeout"); do
    rw_core_on_443 && return 0
    sleep 1
  done
  return 1
}

verify_backend() {
  printf '\n%bПрофиль XHTTP+REALITY :443:%b ' "$B" "$N"
  if rw_core_on_443; then
    printf '%b✓ rw-core слушает 0.0.0.0:443%b\n' "$G" "$N"
    [ -S "$REALITY_SOCKET_DIR/nginx.sock" ] && ok "Self-steal socket готов: $REALITY_SOCKET_TARGET"
  elif [ -n "$SECRET_KEY" ] && $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$'; then
    printf '%bконтейнер поднят, профиль ещё не применён%b\n' "$Y" "$N"
    warn "Назначь ноде Config Profile из $PROFILE_INBOUNDS: один inbound VLESS XHTTP+REALITY на :443."
    warn "Если нода серая — проверь TCP/${NODE_PORT} только от IP панели."
  elif [ -n "$SECRET_KEY" ]; then
    printf '%b✗ контейнер ноды не работает%b\n' "$R" "$N"
    say "  Смотри: ${DIM}docker logs --tail 40 remnanode${N}"
  else
    printf '%b✗ нода не установлена%b\n' "$R" "$N"
    warn "Выбран только фронт Caddy. Для профиля :443 нужен Remnanode."
  fi
}
# ── Домен/путь для standalone-сводки: из env, иначе из существующего Caddyfile
resolve_for_summary() {
  local ip4 public short
  ip4="$(getent ahostsv4 "${DOMAIN:-}" 2>/dev/null | awk 'NR==1{print $1}' || true)"
  [ -n "$ip4" ] || ip4="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  public=""; short=""
  if [ -s "$REALITY_ENV" ]; then
    public="$(awk -F= '/^REALITY_PUBLIC_KEY=/{print substr($0,index($0,"=")+1); exit}' "$REALITY_ENV")"
    short="$(awk -F= '/^REALITY_SHORT_ID=/{print substr($0,index($0,"=")+1); exit}' "$REALITY_ENV")"
  fi

  echo; line
  printf '%b%b  📋 XHTTP + REALITY :443 — ЧТО КУДА ВСТАВЛЯТЬ%b\n' "$B" "$G" "$N"
  line
  cat <<EOF

${B}Нода:${N}
  Домен / SNI          : ${DOMAIN:-—}
  IP сервера           : ${ip4:-—}
  Внешний inbound      : 0.0.0.0:443
  Transport            : VLESS · XHTTP · REALITY
  XHTTP mode           : auto
  XHTTP path           : ${G}${TUNNEL_PATH:-—}${N}
  REALITY target       : ${G}${REALITY_SOCKET_TARGET}${N}
  Caddy fallback       : 127.0.0.1:${CADDY_LOCAL_PORT}
  Public key           : ${public:-—}
  Short ID             : ${short:-—}

${B}Config Profile Remnawave:${N}
  ${C}${PROFILE_INBOUNDS}${N}
  Внутри ОДИН inbound: port 443 · listen 0.0.0.0 · network xhttp · security reality.
  Отдельного внутреннего XHTTP backend-порта эта схема не использует.

${B}Для копипасты прямо в терминал:${N}
  ${C}${MANAGER_PATH} config-profile${N}

${B}Важно:${N}
  Это XHTTP+REALITY self-steal на одном TCP/443.
  REALITY xver=1 приходит на ${REALITY_SOCKET_TARGET}, L4 fallback снимает PROXY header
  и передаёт TLS в Caddy на 127.0.0.1:${CADDY_LOCAL_PORT}.
EOF
  line
}
stage_reality_front() {
  [ -s "$CADDY_REALITY" ] || die "Не найден $CADDY_REALITY"
  [ -s "$CADDY_PUBLIC" ] || $SUDO cp -a "$CADDYFILE" "$CADDY_PUBLIC"

  fix_site_permissions
  $SUDO caddy validate --config "$CADDY_REALITY" --adapter caddyfile || \
    die "Caddyfile REALITY невалиден."

  # Удаляем watcher прошлых версий, если он был установлен.
  $SUDO systemctl disable --now "$PROFILE_WATCH_SERVICE" >/dev/null 2>&1 || true
  $SUDO rm -f "$PROFILE_WATCH_UNIT"
  $SUDO systemctl daemon-reload >/dev/null 2>&1 || true

  if rw_core_on_443; then
    restart_caddy_for_owner || die "rw-core держит :443, но Caddy не удалось запустить на 127.0.0.1:${CADDY_LOCAL_PORT}."
    verify_site_port "$REALITY_PORT"
    ok "Единый XHTTP+REALITY inbound держит :443; self-steal fallback → Caddy 127.0.0.1:${CADDY_LOCAL_PORT}."
    return 0
  fi

  if command -v docker >/dev/null 2>&1 &&
     $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'remnanode' &&
     node_has_443_conflict; then
    warn "Освобождаю TCP/443 для REALITY и жду rw-core; Caddy затем стартует через topology guard."
    $SUDO systemctl stop caddy 2>/dev/null || true
    restart_remnanode_if_present
    if wait_for_rw_core_443 "${REALITY_HANDOFF_WAIT:-35}"; then
      restart_caddy_for_owner || die "rw-core занял :443, но Caddy не удалось запустить на 127.0.0.1:${CADDY_LOCAL_PORT}."
      verify_site_port "$REALITY_PORT"
        ok "Единый XHTTP+REALITY inbound держит :443; self-steal fallback → Caddy 127.0.0.1:${CADDY_LOCAL_PORT}."
      return 0
    fi
    warn "rw-core не занял TCP/443 — возвращаю публичный Caddy."
  fi

  restart_caddy_for_owner || die "Не удалось запустить Caddy в публичном режиме."
  verify_site_port "$REALITY_PORT"
  if final_topology_ready; then
    ok "Профиль активен: XHTTP+REALITY rw-core → :443; Caddy fallback → 127.0.0.1:${CADDY_LOCAL_PORT}."
  else
    ok "Caddy оставлен на публичном TCP/443, потому что rw-core пока не держит :443."
    warn "После назначения REALITY profile watcher/guard освободит :443 для rw-core и переведёт Caddy на 127.0.0.1:${CADDY_LOCAL_PORT}."
  fi
}

# ── Полная установка ─────────────────────────────────────────────────────────
run_install() {
  local mode="${1:-ask}" _cur="" _keep=""   # ask|front
  banner
  install_prerequisites
  # guard повторного запуска: нода уже настроена → по умолчанию ОСТАВЛЯЕМ текущий путь
  # (новый случайный путь рассинхронизирует ноду с Config Profile и Host в панели → трафик встанет).
  # reinstall сначала сносит Caddyfile через clean_node, поэтому там guard не мешает (файла нет → новый путь).
  if [ -z "$TUNNEL_PATH" ] && [ -f "$CADDYFILE" ] && [ "$INTERACTIVE" = 1 ]; then
    _cur="$(current_path)"
    if [ -n "$_cur" ]; then
      warn "Найдена прошлая установка. Текущий туннель-путь: ${G}${_cur}${N}"
      warn "Новый путь рассинхронизирует ноду с Config Profile и Host в панели — трафик встанет, пока не обновишь их."
      printf 'Оставить ТЕКУЩИЙ путь? [Y/n/0]  (n = новый, 0 = назад) '; read -r _keep <"$TTY" || true
      is_menu_back "$_keep" && back_to_menu
      case "${_keep:-Y}" in [Nn]*) : ;; *) TUNNEL_PATH="$_cur" ;; esac
    fi
  fi
  collect_params "$mode"
  say "${B}Параметры:${N}"
  say "  email : ${C}${EMAIL}${N}"
  say "  домен : ${C}${DOMAIN}${N}"
  say "  путь  : ${G}${TUNNEL_PATH}${N}"
  say "  нода  : ${C}$([ -n "$SECRET_KEY" ] && echo 'ставим здесь (Remnanode по SECRET_KEY)' || echo 'НЕ ставим — только фронт Caddy')${N}"
  say "  сайт     : ${C}STREAM → ${WEBROOT}${N}"
  echo
  if [ -z "${REMNA_NONINTERACTIVE:-}" ]; then
    printf 'Продолжить установку? [Y/n/0]  (n/0 = назад в меню) '; read -r yn <"$TTY" || true
    case "${yn:-Y}" in [Nn]|0|q|Q|back|BACK|Back|назад|Назад|НАЗАД) back_to_menu ;; esac
  fi
  install_caddy
  write_caddyfile
  install_stream_site
  start_caddy
  verify_site_port 443
  install_node
  if [ -n "$SECRET_KEY" ]; then
    prepare_profile_files
    stage_reality_front
  fi
  printf '\n%b%bУстановка завершена.%b\n' "$G" "$B" "$N"
  say "  Домен       : ${C}${DOMAIN}${N}"
  say "  Туннель-путь: ${G}${TUNNEL_PATH}${N}"
  say "  Config Profile: ${C}${PROFILE_INBOUNDS}${N}"
  printf '%bПорты 80 и 443 должны быть открыты для выпуска Let'\''s Encrypt.%b\n' "$Y" "$N"
  verify_backend
  summary
}

# ── Снос всего локального (нода + конфиг Caddy + стрим-сайт) ────────────────────
clean_node() {
  log "Снос ноды и фронта Caddy..."
  $SUDO systemctl disable --now "$PROFILE_WATCH_SERVICE" >/dev/null 2>&1 || true
  $SUDO rm -f "$PROFILE_WATCH_UNIT"
  $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
  if command -v docker >/dev/null 2>&1 && [ -f "$NODE_DIR/docker-compose.yml" ]; then
    ( cd "$NODE_DIR" && $SUDO docker compose down ) 2>/dev/null || true
  fi
  $SUDO systemctl disable --now "$FALLBACK_SERVICE" >/dev/null 2>&1 || true
  $SUDO rm -f "$FALLBACK_UNIT"
  $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
  $SUDO docker rm -f remnanode 2>/dev/null || true
  $SUDO rm -rf "$NODE_DIR"
  $SUDO rm -rf "$REALITY_SOCKET_DIR" 2>/dev/null || true
  if [ -f "$CADDYFILE" ]; then
    $SUDO cp "$CADDYFILE" "${CADDYFILE}.bak.$(date +%s 2>/dev/null || echo old)" 2>/dev/null || true
    $SUDO rm -f "$CADDYFILE"
  fi
  $SUDO rm -rf "$WEBROOT" 2>/dev/null || true
  $SUDO systemctl stop caddy 2>/dev/null || true
  ok "Снесено: контейнер remnanode, $NODE_DIR, $CADDYFILE (бэкап рядом), стрим-сайт."
  warn "Firewall и сам пакет Caddy не тронуты. Запись ноды и профиль в панели удали отдельно, если нужно."
}

# ── Переустановка с нуля ─────────────────────────────────────────────────────
run_reinstall() {
  banner
  warn "Переустановка снесёт локальную ноду и конфиг Caddy, затем поставит заново с НОВЫМ путём."
  if [ -z "${REMNA_NONINTERACTIVE:-}" ]; then
    printf 'Продолжить? [y/N/0]  (N/0 = назад в меню) '; read -r yn <"$TTY" || true
    case "${yn:-N}" in [Yy]*) : ;; *) back_to_menu ;; esac
  fi
  clean_node
  TUNNEL_PATH=""        # форсируем генерацию нового пути
  run_install ask
}

# ── Сгенерировать/показать туннель-путь ──────────────────────────────────────
cmd_path() {
  local p; p="$(gen_path)"
  banner
  printf '  Новый туннель-путь: %b%s%b\n\n' "$G" "$p" "$N"
  say  "  Вставь его в ТРИ места (должны совпадать):"
  say  "   ${DIM}•${N} инбаунд ноды (Config Profile): path и extra.path = ${G}${p}${N}"
  say  "   ${DIM}•${N} Config Profile: xhttpSettings.path = ${G}${p}${N}"
  say  "   ${DIM}•${N} хост Remnawave → поле «Путь» = ${G}${p}${N}"
  echo
  say  "  ${DIM}Либо сгенерируй путь в браузере (кнопка 🎲 в конструкторе на странице гайда) —${N}"
  say  "  ${DIM}алгоритм тот же. Главное: один и тот же путь во всех местах.${N}"
}


cmd_path_set() {
  banner
  resolve_existing
  local requested="${1:-}" old backup_dir f tmp
  if [ -z "$requested" ] && [ "$INTERACTIVE" = 1 ]; then
    printf 'Новый XHTTP-путь (0 = назад): '
    read -r requested <"$TTY" || true
    is_menu_back "$requested" && back_to_menu
  fi
  [ -n "$requested" ] || die "Укажи путь: $0 path-set /new/path.php"
  requested="$(normalize_path "$requested")"
  old="$(current_path)"
  [ -n "$old" ] || die "Не удалось определить текущий путь."
  [ "$requested" != "$old" ] || { ok "Путь уже установлен: $requested"; return 0; }
  backup_dir="/root/caddy-path-backup-$(date +%Y%m%d-%H%M%S)"
  $SUDO install -d -o root -g root -m 0700 "$backup_dir"
  for f in "$CADDYFILE" "$CADDY_PUBLIC" "$CADDY_REALITY"; do
    [ -f "$f" ] && $SUDO cp -a "$f" "$backup_dir/$(basename "$f")"
  done
  for f in "$CADDYFILE" "$CADDY_PUBLIC" "$CADDY_REALITY"; do
    [ -f "$f" ] || continue
    tmp="$(mktemp)"
    awk -v old="$old" -v new="$requested" '
      function repl(str, old, new, pos, out) {
        out=""
        while ((pos=index(str, old)) > 0) {
          out=out substr(str,1,pos-1) new
          str=substr(str,pos+length(old))
        }
        return out str
      }
      { print repl($0, old, new) }
    ' "$f" > "$tmp"
    $SUDO install -o root -g root -m 0644 "$tmp" "$f"
    rm -f "$tmp"
    $SUDO caddy validate --config "$f" --adapter caddyfile >/dev/null || {
      warn "Ошибка валидации $f; возвращаю бэкап."
      for f in "$CADDYFILE" "$CADDY_PUBLIC" "$CADDY_REALITY"; do
        [ -f "$backup_dir/$(basename "$f")" ] && $SUDO cp -a "$backup_dir/$(basename "$f")" "$f"
      done
      die "Путь не изменён."
    }
  done
  TUNNEL_PATH="$requested"
  reload_or_restart_caddy_for_owner || {
    for f in "$CADDYFILE" "$CADDY_PUBLIC" "$CADDY_REALITY"; do
      [ -f "$backup_dir/$(basename "$f")" ] && $SUDO cp -a "$backup_dir/$(basename "$f")" "$f"
    done
    restart_caddy_for_owner || true
    die "Caddy не применил новый путь; выполнен откат."
  }
  if [ -s "$REALITY_ENV" ]; then
    write_profile_inbound
    write_profile_bundle
  fi
  ok "XHTTP-путь изменён: $old → $requested"
  warn "Теперь поставь тот же путь в Config Profile и Host Remnawave."
}

# ── Статус сервисов ──────────────────────────────────────────────────────────
cmd_status() {
  banner
  printf '  %bCaddy%b     : ' "$B" "$N"
  $SUDO systemctl is-active caddy 2>/dev/null || echo "не активен"
  printf '  %bRemnanode%b : ' "$B" "$N"
  if $SUDO docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep '^remnanode' ; then :; else echo "не запущен"; fi
  printf '  %bFallback%b  : ' "$B" "$N"
  $SUDO systemctl is-active "$FALLBACK_SERVICE" 2>/dev/null || echo "не активен"
  printf '  %bПорты%b     :\n' "$B" "$N"
  ss -lntp 2>/dev/null | grep -E ":80 |:443 |127\.0\.0\.1:${CADDY_LOCAL_PORT}|:${NODE_PORT} " | sed 's/^/    /' || true
  printf '  %bSocket%b    : %s\n' "$B" "$N" "$([ -S "$REALITY_SOCKET_DIR/nginx.sock" ] && echo "$REALITY_SOCKET_TARGET ready" || echo "missing")"
  if [ -f "$CADDYFILE" ]; then
    printf '  %bXHTTP path%b: %s\n' "$B" "$N" "$(current_path)"
  fi
}
# ── Диагностика единого XHTTP+REALITY inbound :443 ───────────────────────────
cmd_diagnose() {
  set +e; trap - ERR
  banner
  local fail=0 path
  path="$(current_path)"; [ -n "$path" ] || path="—"
  line; printf '%b  Диагностика XHTTP+REALITY :443%b\n' "$B" "$N"; line

  if $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
    ok "Remnanode запущен"
  else
    warn "Remnanode не запущен"; fail=$((fail+1))
  fi

  if rw_core_on_443; then
    ok "rw-core слушает единый XHTTP+REALITY inbound на :443"
    caddy_local_8443 && ok "Caddy fallback слушает 127.0.0.1:${CADDY_LOCAL_PORT}" || { warn "Caddy fallback :${CADDY_LOCAL_PORT} отсутствует"; fail=$((fail+1)); }
    [ -S "$REALITY_SOCKET_DIR/nginx.sock" ] && ok "Host self-steal socket существует" || { warn "Нет $REALITY_SOCKET_DIR/nginx.sock"; fail=$((fail+1)); }
    $SUDO docker exec remnanode test -S "$REALITY_SOCKET_TARGET" >/dev/null 2>&1 && ok "Socket виден в remnanode как $REALITY_SOCKET_TARGET" || { warn "remnanode не видит $REALITY_SOCKET_TARGET"; fail=$((fail+1)); }
  elif caddy_public_443; then
    ok "Caddy публично держит :443; Config Profile ещё не активировал rw-core"
  else
    warn "Ни rw-core, ни Caddy не держат :443"; fail=$((fail+1))
  fi

  if ss -lntp 2>/dev/null | grep -q ":${NODE_PORT} "; then ok "Node API :${NODE_PORT} слушает"; else warn "Node API :${NODE_PORT} не слушает"; fail=$((fail+1)); fi
  printf '  XHTTP path  : %s\n' "$path"
  printf '  Profile JSON: %s\n' "$PROFILE_INBOUNDS"
  show_topology
  set -e
  [ "$fail" -eq 0 ] && { ok "Диагностика: PASS"; return 0; }
  warn "Диагностика: найдено проблем: $fail"
  return 1
}
# ── Обновить стрим-сайт ──────────────────────────────────────────────────────
cmd_stream() {
  banner
  FORCE_STREAM_REFRESH=1 install_stream_site
  ok "Стрим-сайт обновлён; рестарт Caddy не требуется."
}
cmd_decoy() { cmd_stream; }

# ── REALITY self-steal: подготовка и переключение ─────────────────────────────
resolve_existing() {
  [ -f "$CADDYFILE" ] || die "Не найден $CADDYFILE."
  if [ -z "$DOMAIN" ]; then
    DOMAIN="$(awk '/^[A-Za-z0-9].*\{[[:space:]]*$/{gsub(/[[:space:]]*\{[[:space:]]*$/,"",$0); print $1; exit}' "$CADDYFILE" 2>/dev/null || true)"
  fi
  [ -n "$TUNNEL_PATH" ] || TUNNEL_PATH="$(current_path)"
  [ -n "$DOMAIN" ] || die "Не удалось определить DOMAIN из $CADDYFILE."
  [ -n "$TUNNEL_PATH" ] || die "Не удалось определить существующий XHTTP-путь из $CADDYFILE."
  EMAIL="${EMAIL:-$(awk '/^[[:space:]]*email /{print $2; exit}' "$CADDYFILE" 2>/dev/null || true)}"
  [ -n "$EMAIL" ] || die "Не удалось определить email из $CADDYFILE."
}

generate_reality_material() {
  $SUDO install -d -o root -g root -m 0700 "$REALITY_DIR"
  if [ -s "$REALITY_ENV" ]; then
    ok "Ключи REALITY уже существуют → $REALITY_ENV"
    return 0
  fi
  local core raw private public short
  core="$(command -v rw-core || true)"
  [ -n "$core" ] || core=/usr/local/bin/rw-core
  if [ -x "$core" ]; then
    raw="$($SUDO "$core" x25519 2>/dev/null)" || die "rw-core x25519 завершился ошибкой."
  elif command -v docker >/dev/null 2>&1 && $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'remnanode'; then
    raw="$($SUDO docker exec remnanode /usr/local/bin/rw-core x25519 2>/dev/null)" || die "Не удалось выполнить rw-core x25519 внутри remnanode."
  else
    die "rw-core не найден ни на хосте, ни в контейнере remnanode."
  fi
  private="$(printf '%s\n' "$raw" | sed -nE 's/^[[:space:]]*(PrivateKey|Private key):[[:space:]]*//p' | head -1)"
  public="$(printf '%s\n' "$raw" | sed -nE 's/^[[:space:]]*(Password([[:space:]]*\([^)]*\))?|PublicKey|Public key):[[:space:]]*//p' | head -1)"
  [ -n "$private" ] && [ -n "$public" ] || die "Не удалось разобрать вывод rw-core x25519."
  short="$(openssl rand -hex 8)"
  umask 077
  cat > "$REALITY_ENV" <<EOF
REALITY_PRIVATE_KEY=$private
REALITY_PUBLIC_KEY=$public
REALITY_SHORT_ID=$short
REALITY_SERVER_NAME=$DOMAIN
REALITY_TARGET=$REALITY_SOCKET_TARGET
EOF
  chmod 600 "$REALITY_ENV"
  unset private public raw
  ok "Ключи REALITY сохранены с правами 600 → $REALITY_ENV"
}

write_profile_inbound() {
  # shellcheck disable=SC1090
  . "$REALITY_ENV"
  local first tag
  first="${DOMAIN%%.*}"
  if [[ "$first" =~ ^([A-Za-z]{2})([0-9]+)$ ]]; then
    tag="${BASH_REMATCH[1]^^}-node${BASH_REMATCH[2]}-xHTTP"
  else
    tag="$(printf '%s' "$first" | sed -E 's/[^A-Za-z0-9_-]+/-/g')-xHTTP"
  fi

  umask 077
  cat > "$PROFILE_INBOUND" <<EOF
{
  "tag": "$tag",
  "port": 443,
  "listen": "0.0.0.0",
  "protocol": "vless",
  "settings": {
    "clients": [],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "reality",
    "xhttpSettings": {
      "mode": "auto",
      "path": "$TUNNEL_PATH",
      "extra": {
        "xmux": {
          "cMaxReuseTimes": 12,
          "maxConcurrency": 1
        },
        "seqKey": "visitor_id",
        "xPaddingKey": "_r",
        "seqPlacement": "cookie",
        "sessionIDKey": "auth_session",
        "xPaddingBytes": "270-1096",
        "sessionIDTable": "Base62",
        "xPaddingHeader": "X-Request-Token",
        "xPaddingMethod": "tokenish",
        "sessionIDLength": "16-32",
        "xPaddingObfsMode": true,
        "xPaddingPlacement": "queryInHeader",
        "sessionIDPlacement": "cookie"
      }
    },
    "realitySettings": {
      "show": false,
      "xver": 1,
      "target": "$REALITY_SOCKET_TARGET",
      "shortIds": [
        "$REALITY_SHORT_ID"
      ],
      "privateKey": "$REALITY_PRIVATE_KEY",
      "serverNames": [
        "$DOMAIN"
      ],
      "minClientVer": "1"
    }
  }
}
EOF
  chmod 600 "$PROFILE_INBOUND"
  ok "XHTTP+REALITY inbound :443 → $PROFILE_INBOUND"
}

write_profile_bundle() {
  umask 077
  {
    printf '{\n  "inbounds": [\n'
    sed 's/^/    /' "$PROFILE_INBOUND"
    printf '  ]\n}\n'
  } > "$PROFILE_INBOUNDS"
  chmod 600 "$PROFILE_INBOUNDS"
  ok "Готовый Config Profile → $PROFILE_INBOUNDS"
}

prepare_profile_files() {
  generate_reality_material
  write_caddyfile_reality
  install_reality_socket_proxy
  write_profile_inbound
  write_profile_bundle
  rm -f "$REALITY_DIR/reality-inbound.json" "$REALITY_DIR/xhttp-inbound.json"
}

cmd_reality_prepare() {
  banner
  resolve_existing
  [ -s "$WEBROOT/index.html" ] || install_stream_site
  fix_site_permissions
  [ -s "$CADDY_PUBLIC" ] || $SUDO cp -a "$CADDYFILE" "$CADDY_PUBLIC"
  prepare_profile_files
  echo; line
  say "${B}Подготовлен единый XHTTP+REALITY inbound на 0.0.0.0:443.${N}"
  say "  Готовый Config Profile : ${C}${PROFILE_INBOUNDS}${N}"
  say "  REALITY target         : ${C}${REALITY_SOCKET_TARGET}${N}"
  say "  XHTTP path             : ${G}${TUNNEL_PATH}${N}"
  say "  После назначения профиля в панели: ${C}${MANAGER_PATH} reality-enable${N}"
  line
}
reality_enable_impl() {
  resolve_existing
  [ -s "$CADDY_REALITY" ] || prepare_profile_files
  install_reality_socket_proxy
  $SUDO caddy validate --config "$CADDY_REALITY" --adapter caddyfile || die "Caddyfile REALITY невалиден."
  [ -s "$CADDY_PUBLIC" ] || $SUDO cp -a "$CADDYFILE" "$CADDY_PUBLIC"
  fix_site_permissions

  if rw_core_on_443; then
    restart_caddy_for_owner || die "rw-core держит :443, но Caddy не удалось запустить на 127.0.0.1:${CADDY_LOCAL_PORT}."
    verify_site_port "$REALITY_PORT"
    final_topology_ready || warn "Проверь shared /dev/shm mount и self-steal socket."
    ok "Готово: XHTTP+REALITY :443 → ${REALITY_SOCKET_TARGET} → Caddy 127.0.0.1:${CADDY_LOCAL_PORT}"
    show_topology
    return 0
  fi

  warn "Освобождаю TCP/443 для единого XHTTP+REALITY inbound."
  $SUDO systemctl stop caddy 2>/dev/null || true
  restart_remnanode_if_present
  if wait_for_rw_core_443 "${REALITY_HANDOFF_WAIT:-120}"; then
    restart_caddy_for_owner || die "rw-core занял :443, но Caddy fallback не запустился на 127.0.0.1:${CADDY_LOCAL_PORT}."
    verify_site_port "$REALITY_PORT"
    final_topology_ready || warn "Профиль :443 поднялся, но self-steal topology неполна."
    ok "Готово: XHTTP+REALITY :443 → ${REALITY_SOCKET_TARGET} → Caddy 127.0.0.1:${CADDY_LOCAL_PORT}"
    show_topology
    return 0
  fi

  warn "rw-core не занял :443; возвращаю публичный Caddy."
  restart_caddy_for_owner || true
  verify_site_port 443 || true
  $SUDO docker logs --since 5m remnanode 2>&1 | tr -d '\000' | tail -60 || true
  die "XHTTP+REALITY inbound :443 не запустился. Проверь Config Profile."
}
cmd_reality_enable() {
  banner
  $SUDO systemctl stop "$PROFILE_WATCH_SERVICE" >/dev/null 2>&1 || true
  reality_enable_impl
}

cmd_reality_disable() {
  banner
  $SUDO systemctl stop "$PROFILE_WATCH_SERVICE" >/dev/null 2>&1 || true
  if ss -lntp 2>/dev/null | grep -E ':443[[:space:]]' | grep -q 'rw-core'; then
    die "Сначала удали/отключи Reality inbound в Config Profile и дождись освобождения :443."
  fi
  [ -s "$CADDY_PUBLIC" ] || die "Не найден $CADDY_PUBLIC"
  restart_caddy_for_owner || die "Публичный Caddyfile невалиден или Caddy не запустился."
  ok "Возвращён публичный Caddy на :443."
}

cmd_reality_info() {
  banner
  printf '  %-26s %s\n' 'Config Profile:' "$PROFILE_INBOUNDS"
  printf '  %-26s %s\n' 'Inbound XHTTP+REALITY:' "$PROFILE_INBOUND"
  printf '  %-26s %s\n' 'REALITY ключи:' "$REALITY_ENV"
  printf '  %-26s %s\n' 'REALITY target:' "$REALITY_SOCKET_TARGET"
  printf '  %-26s %s\n' 'Caddy fallback:' "$CADDY_REALITY"
  echo
  say "  Private key намеренно не выводится этой командой."
  show_topology
}

print_profile_json() {
  echo
  line
  printf '%b%b  CONFIG PROFILE — XHTTP + REALITY :443 — КОПИРУЙ НИЖЕ%b\n' "$B" "$G" "$N"
  line
  cat "$PROFILE_INBOUNDS"
  line
}

cmd_config_profile() {
  banner
  resolve_existing
  if [ ! -s "$PROFILE_INBOUNDS" ]; then
    warn "Готовый Config Profile ещё не создан."
    say "  Сначала выбери «Подготовить профиль» или выполни:"
    say "  ${C}${MANAGER_PATH} reality-prepare${N}"
    return 1
  fi
  warn "JSON содержит REALITY privateKey. Не публикуй его."
  print_profile_json
}
cmd_repair() {
  banner
  install_prerequisites
  resolve_existing
  install_caddy
  [ -s "$WEBROOT/index.html" ] || install_stream_site
  fix_site_permissions
  [ -s "$CADDY_PUBLIC" ] || $SUDO cp -a "$CADDYFILE" "$CADDY_PUBLIC"
  prepare_profile_files

  if ss -lntp 2>/dev/null | grep -E ':443[[:space:]]' | grep -q 'rw-core'; then
    reality_enable_impl
  elif node_has_443_conflict; then
    warn "Обнаружен конфликт Caddy и REALITY за TCP/443 — исправляю."
    reality_enable_impl
  elif ss -lntp 2>/dev/null | grep -q "127.0.0.1:${CADDY_LOCAL_PORT}"; then
    warn "Caddy уже локальный, но rw-core не слушает 443; пробую перезапустить ноду."
    reality_enable_impl
  else
    start_caddy
    verify_site_port 443
    if rw_core_on_443; then
      ok "XHTTP+REALITY профиль активен на :443."
    else
      warn "Сайт исправлен. Единый XHTTP+REALITY inbound появится после назначения Config Profile."
    fi
  fi

  echo; line
  say "${B}Исправление завершено.${N}"
  say "  Готовый профиль inbound: ${C}${PROFILE_INBOUNDS}${N}"
  say "  В панели используй DOMAIN=${G}${DOMAIN}${N} для Origin, Referer и REALITY serverNames."
  line
}

# ── Меню ─────────────────────────────────────────────────────────────────────
menu() {
  banner
  printf '  %b📌 Выберите действие:%b\n\n' "$B" "$N"
  printf '   %b[1]%b  🚀  Полная установка       %b— нода (по SECRET_KEY) + Caddy + стрим-сайт + проверки%b\n' "$G" "$N" "$DIM" "$N"
  printf '   %b[2]%b  🔄  Переустановить с нуля   %b— снос ноды/конфига и установка заново (новый путь)%b\n' "$C" "$N" "$DIM" "$N"
  printf '   %b[3]%b  🛡   Только фронт Caddy      %b— ноду поднимаешь отдельно%b\n' "$BL" "$N" "$DIM" "$N"
  printf '   %b[4]%b  🎲  Сгенерировать путь      %b— случайный туннель-путь (как в браузере)%b\n' "$M" "$N" "$DIM" "$N"
  printf '   %b[5]%b  📻  Обновить стрим-сайт     %b— загрузить рабочую страницу заново%b\n' "$G" "$N" "$DIM" "$N"
  printf '   %b[6]%b  📋  Что и куда вставлять    %b— Config Profile / Host Remnawave%b\n' "$BL" "$N" "$DIM" "$N"
  printf '   %b[7]%b  🩺  Диагностика            %b— симптом → причина → фикс%b\n' "$M" "$N" "$DIM" "$N"
  printf '   %b[8]%b  📊  Статус сервисов        %b— caddy / remnanode / порты%b\n' "$Y" "$N" "$DIM" "$N"
  printf '   %b[9]%b  🔐  Подготовить профиль     %b— единый XHTTP+REALITY :443%b\n' "$C" "$N" "$DIM" "$N"
  printf '   %b[10]%b ⚡  Включить REALITY        %b— переключить один внешний TCP/443%b\n' "$G" "$N" "$DIM" "$N"
  printf '   %b[11]%b ↩   Отключить REALITY       %b— вернуть публичный Caddy:443%b\n' "$Y" "$N" "$DIM" "$N"
  printf '   %b[12]%b 📋  Профиль для копипасты   %b— готовый XHTTP+REALITY :443%b\n' "$BL" "$N" "$DIM" "$N"
  printf '   %b[13]%b 🛠   Repair Caddy / XHTTP / REALITY %b— сайт, конфиги и конфликт TCP/443%b\n' "$G" "$N" "$DIM" "$N"
  printf '   %b[14]%b 🧹  Снести всё (clean)      %b— удалить ноду и конфиг Caddy%b\n' "$R" "$N" "$DIM" "$N"
  printf '   %b[0]%b  🚪  Выход\n' "$DIM" "$N"
  echo
  printf '  Выбор: '; read -r choice <"$TTY" || true; echo
  case "$choice" in
    1) run_install ask ;;
    2) run_reinstall ;;
    3) run_install front ;;
    4) cmd_path ;;
    5) cmd_stream ;;
    6) resolve_for_summary; summary ;;
    7) cmd_diagnose ;;
    8) cmd_status ;;
    9) cmd_reality_prepare ;;
    10) cmd_reality_enable ;;
    11) cmd_reality_disable ;;
    12) cmd_config_profile ;;
    13) cmd_repair ;;
    14) clean_node ;;
    0|"") exit 0 ;;
    *) die "Неизвестный пункт: $choice" ;;
  esac
}

# ── Точка входа ──────────────────────────────────────────────────────────────
main() {
  local cmd="${1:-menu}"
  persist_self || true
  case "$cmd" in
    install|--auto|auto)   run_install ask ;;
    front-only|front)      run_install front ;;
    reinstall)             run_reinstall ;;
    path|gen-path)         cmd_path ;;
    path-set|set-path)     cmd_path_set "${2:-}" ;;
    summary|info)          resolve_for_summary; summary ;;
    diagnose|diag)         cmd_diagnose ;;
    status)                cmd_status ;;
    repair|fix)            cmd_repair ;;
    stream|site|decoy|set-decoy) cmd_stream ;;
    reality-prepare)        cmd_reality_prepare ;;
    reality-enable)         cmd_reality_enable ;;
    reality-disable)        cmd_reality_disable ;;
    reality-info)           cmd_reality_info ;;
    config-profile|profile-json|profile) cmd_config_profile ;;
    clean|uninstall)       clean_node ;;
    menu|"")               menu ;;
    -h|--help|help)        sed -n '18,43p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "Неизвестная команда: $cmd (см. --help)" ;;
  esac
}

main "$@"
