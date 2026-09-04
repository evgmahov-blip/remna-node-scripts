#!/usr/bin/env bash
GHOST_LIC='3b260369'
GHOST_ID='cfac14d415274f93'
GHOST_SCRIPT_ID='caddy-node'
GHOST_SITE='https://info.ghostos.space'
GHOST_DL='https://sh.ghostos.space'
GHOST_Q='?lic=cfac14d415274f93'
export GHOST_LIC GHOST_ID GHOST_SCRIPT_ID GHOST_SITE GHOST_DL GHOST_Q
# GHOST OS · license 3b260369 · id cfac14d415274f93 · caddy-node · 2026-08-06T13:55:42.583Z · ip 139.100.235.157 · (c) GHOST OS — do not remove
#‍​​‌‌​​‌‌​‌‌​​​‌​​​‌‌​​‌​​​‌‌​‌‌​​​‌‌​​​​​​‌‌​​‌‌​​‌‌​‌‌​​​‌‌‌​​‌‍ 
GHOST_V="$(curl -fsS --max-time 6 "$GHOST_SITE/api/script/verify?lic=${GHOST_ID}&s=${GHOST_SCRIPT_ID}" 2>/dev/null || true)"
if printf "%s" "$GHOST_V" | grep -q '"allow":false'; then
  echo "[GHOST OS] Скрипт не привязан к лицензии или ключ отозван."
  echo "[GHOST OS] Персональная команда установки — в кабинете: $GHOST_SITE/pages/profile"
  echo "[GHOST OS] Поддержка: @Kto_berserk"
  exit 1
fi
# ============================================================================
#  version: r9
#  install-caddy-node-reality-stream.sh — Caddy + стрим-сайт для основной
#  XHTTP-ноды за Beeline CDN и подготовка второго VLESS RAW REALITY Vision
#  на том же внешнем TCP/443. Опционально поднимает Remnanode. Caddy выбирает
#  режим по фактическому владельцу TCP/443: rw-core на :443 → локальный
#  127.0.0.1:8443, rw-core нет → публичный :443.
#
#  Запуск без аргументов открывает МЕНЮ. Также доступны подкоманды:
#    install | --auto   полная установка (нода по SECRET_KEY + Caddy)
#    front-only         только фронт Caddy (ноду поднять отдельно)
#    reinstall          снос всего локального + установка заново
#    path               сгенерировать/показать туннель-путь
#    path-set PATH      изменить XHTTP-путь в Caddy-конфигах
#    summary            «что и куда вставлять» (CDN + панель Remnawave)
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
#  Одна команда из публичного GitHub:
#    bash -c 'apt-get update -y && apt-get install -y curl ca-certificates && install -d -m 755 /opt/remna-node-scripts && curl -fsSL https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/main/install-caddy-node-reality-stream.sh -o /opt/remna-node-scripts/install-caddy-node-reality-stream.sh && chmod 700 /opt/remna-node-scripts/install-caddy-node-reality-stream.sh && exec /opt/remna-node-scripts/install-caddy-node-reality-stream.sh install'
#
#  Неинтерактивно:
#    EMAIL=you@mail.com DOMAIN=node.example.net SECRET_KEY=... \
#      STREAM_SITE_URL=https://rustream.remna.space/ bash $0 --auto
# ============================================================================
set -Eeo pipefail

# ── Порты (фиксированные для метода) ─────────────────────────────────────────
BACKEND_PORT=7443       # основной XHTTP-инбаунд (127.0.0.1:7443)
NODE_PORT=2222          # API-порт ноды Remnawave (mTLS)
REALITY_PORT=443        # второй прямой inbound VLESS RAW REALITY Vision
CADDY_LOCAL_PORT=8443   # локальный HTTPS Caddy за REALITY self-steal
CADDYFILE=/etc/caddy/Caddyfile
CADDY_PUBLIC=/etc/caddy/Caddyfile.public
CADDY_REALITY=/etc/caddy/Caddyfile.reality
NODE_DIR=/opt/remnanode
REALITY_DIR=/opt/remnanode/reality
REALITY_ENV=$REALITY_DIR/reality.env
REALITY_INBOUND=$REALITY_DIR/reality-inbound.json
XHTTP_INBOUND=$REALITY_DIR/xhttp-inbound.json
PROFILE_INBOUNDS=$REALITY_DIR/inbounds-ready.json
SCRIPT_INSTALL_DIR=/opt/remna-node-scripts
SCRIPT_INSTALL_PATH=$SCRIPT_INSTALL_DIR/install-caddy-node-reality-stream.sh
CADDY_GUARD=$SCRIPT_INSTALL_DIR/caddy-resilient-start.sh
PROFILE_WATCH_SERVICE=remna-profile-wait.service  # legacy: удаляется при обновлении/сносе
PROFILE_WATCH_UNIT=/etc/systemd/system/$PROFILE_WATCH_SERVICE
WEBROOT=/var/www/mstream
STREAM_SITE_URL="${STREAM_SITE_URL:-https://rustream.remna.space}"
STREAM_SITE_ARCHIVE="${STREAM_SITE_ARCHIVE:-}"
STREAM_HEALTH_UPSTREAM="${STREAM_HEALTH_UPSTREAM:-https://stream.deepbeat.ru:8443/health}"
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

banner() {
  echo
  printf '  %b%b────────────────────────────────────────────────────────────%b\n' "$B" "$C" "$N"
  printf '  %b%b🌐 INFO GHOST OS%b  %b·%b  %bCDN XHTTP + REALITY%b  %b·%b  %bSTREAM%b\n' \
    "$B" "$C" "$N" "$DIM" "$N" "$B" "$N" "$DIM" "$N" "$M" "$N"
  printf '  %bОсновной: XHTTP/CDN · второй: RAW/REALITY/Vision · один внешний TCP/443%b\n' "$DIM" "$N"
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
  [ "$current" = "$SCRIPT_INSTALL_PATH" ] && [ -s "$SCRIPT_INSTALL_PATH" ] && return 0
  case "$current" in /dev/fd/*|/proc/*/fd/*) return 0 ;; esac
  [ -f "$current" ] && [ -s "$current" ] || return 0
  $SUDO install -d -o root -g root -m 0755 "$SCRIPT_INSTALL_DIR"
  $SUDO install -o root -g root -m 0700 "$current" "$SCRIPT_INSTALL_PATH"
  ok "Скрипт сохранён → $SCRIPT_INSTALL_PATH"
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
  for cmd in curl wget openssl ss shuf tar awk sed grep; do
    command -v "$cmd" >/dev/null 2>&1 || missing=1
  done
  [ "$missing" -eq 0 ] && [ -s /etc/ssl/certs/ca-certificates.crt ] && return 0
  log "Устанавливаю базовые зависимости..."
  apt_get update -y
  apt_get install -y curl wget ca-certificates openssl iproute2 coreutils tar gawk sed grep
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
    printf 'XHTTP-путь (Enter = сгенерировать случайный): '
    read -r entered <"$TTY" || true
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
  [ -n "$EMAIL" ] || { [ "$INTERACTIVE" = 1 ] || die "EMAIL не задан. Передай через env: EMAIL=you@mail.com bash $0 --auto"; printf 'Email (для Let'\''s Encrypt): '; read -r EMAIL <"$TTY" || true; }
  while ! printf '%s' "$EMAIL" | grep -q '@'; do
    [ "$INTERACTIVE" = 1 ] || die "EMAIL некорректен/не задан (env: EMAIL=...)."
    printf '  Некорректный email, повтори: '; read -r EMAIL <"$TTY" || true
  done
  [ -n "$DOMAIN" ] || { [ "$INTERACTIVE" = 1 ] || die "DOMAIN не задан. Передай через env: DOMAIN=node.example.net bash $0 --auto"; printf 'Домен ноды (например finka.example.ru): '; read -r DOMAIN <"$TTY" || true; }
  DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%/}"
  DOMAIN="$(printf '%s' "$DOMAIN" | tr -d '[:space:]')"
  [ -n "$DOMAIN" ] || die "Домен пустой."

  if [ "$need_node" != "front" ] && [ -z "$SECRET_KEY" ]; then
    printf 'Поставить ноду здесь же? Вставь SECRET_KEY из панели Remnawave (Enter = только фронт).\n'
    printf '%b  ввод СКРЫТ — символы не отображаются, это нормально. Вставляй ТОЛЬКО значение ключа,%b\n' "$DIM" "$N"
    printf '%b  без «SECRET_KEY=» и без кавычек.%b\n' "$DIM" "$N"
    printf 'SECRET_KEY: '
    read -rs SECRET_KEY <"$TTY" || true; echo
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
  $SUDO install -d -o root -g root -m 0700 "$NODE_DIR"
  local compose_tmp; compose_tmp="$(mktemp)"
  cat >"$compose_tmp" <<NODE_EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ${REMNA_NODE_IMAGE}
    network_mode: host
    restart: always
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

  handle /api/deepbeat-health* {
    rewrite * /health
    reverse_proxy https://stream.deepbeat.ru:8443 {
      header_up Host stream.deepbeat.ru
      transport http {
        tls_server_name stream.deepbeat.ru
        dial_timeout 7s
        response_header_timeout 15s
      }
    }
  }

  @tunnel {
    path __PATH__*
    query auth=*
  }
  handle @tunnel {
    rewrite * __PATH__/
    reverse_proxy 127.0.0.1:__BACKEND__ {
      flush_interval -1
      header_up Host {host}
      header_up X-Real-IP {remote_host}
      transport http {
        versions h2c 1.1
        keepalive_idle_conns 256
        keepalive 30s
      }
    }
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
  sed -i "s|__EMAIL__|${se}|g; s|__DOMAIN__|${sd}|g; s|__PATH__|${sp}|g; s|__BACKEND__|${BACKEND_PORT}|g; s|__WEBROOT__|${sw}|g; s|__CADDY_LOCAL__|${CADDY_LOCAL_PORT}|g" "$file"
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

  handle /api/deepbeat-health* {
    rewrite * /health
    reverse_proxy https://stream.deepbeat.ru:8443 {
      header_up Host stream.deepbeat.ru
      transport http {
        tls_server_name stream.deepbeat.ru
        dial_timeout 7s
        response_header_timeout 15s
      }
    }
  }

  @tunnel {
    path __PATH__*
    query auth=*
  }
  handle @tunnel {
    rewrite * __PATH__/
    reverse_proxy 127.0.0.1:__BACKEND__ {
      flush_interval -1
      header_up Host {host}
      header_up X-Real-IP {remote_host}
      transport http {
        versions h2c 1.1
        keepalive_idle_conns 256
        keepalive 30s
      }
    }
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

fix_site_permissions() {
  [ -d "$WEBROOT" ] || return 0
  $SUDO chmod 755 /var /var/www "$WEBROOT" 2>/dev/null || true
  $SUDO find "$WEBROOT" -type d -exec chmod 755 {} +
  $SUDO find "$WEBROOT" -type f -exec chmod 644 {} +
}

# ── Стрим-сайт: локальный архив или копирование с рабочего сайта ─────────────
install_stream_site() {
  $SUDO mkdir -p "$WEBROOT"

  if [ -n "$STREAM_SITE_ARCHIVE" ]; then
    local archive="$STREAM_SITE_ARCHIVE" tmpa="" tmpd
    tmpd="$(mktemp -d)"
    if printf '%s' "$archive" | grep -qE '^https?://'; then
      tmpa="$(mktemp)"
      curl -fsSL --max-time 60 "$archive" -o "$tmpa" || die "Не удалось скачать STREAM_SITE_ARCHIVE."
      archive="$tmpa"
    fi
    [ -f "$archive" ] || die "Архив стрим-сайта не найден: $archive"
    tar -xf "$archive" -C "$tmpd" || die "Не удалось распаковать архив стрим-сайта."
    local idx; idx="$(find "$tmpd" -type f -name index.html -print -quit)"
    [ -n "$idx" ] || die "В архиве нет index.html."
    $SUDO find "$WEBROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    $SUDO cp -a "$(dirname "$idx")"/. "$WEBROOT"/
    rm -rf "$tmpd"; [ -z "$tmpa" ] || rm -f "$tmpa"
    fix_site_permissions
    ok "Стрим-сайт установлен из архива → $WEBROOT"
    return 0
  fi

  if [ -s "$WEBROOT/index.html" ] && [ "${FORCE_STREAM_REFRESH:-0}" != 1 ]; then
    fix_site_permissions
    ok "Стрим-сайт уже существует → $WEBROOT (не перезаписываю)"
    return 0
  fi

  local tmpd idx
  tmpd="$(mktemp -d)"
  if command -v wget >/dev/null 2>&1; then
    wget -q --timeout=20 --tries=2 --page-requisites --convert-links \
      --adjust-extension --no-host-directories --directory-prefix="$tmpd" \
      "$STREAM_SITE_URL" || true
  else
    curl -fsSL --max-time 30 "$STREAM_SITE_URL" -o "$tmpd/index.html" || true
  fi
  idx="$(find "$tmpd" -type f -name 'index.html*' -print -quit)"
  if [ -z "$idx" ] || [ ! -s "$idx" ]; then
    rm -rf "$tmpd"
    die "Не удалось получить стрим-сайт с $STREAM_SITE_URL. Передай STREAM_SITE_ARCHIVE=/путь/site.tar.gz"
  fi
  $SUDO find "$WEBROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  $SUDO cp -a "$(dirname "$idx")"/. "$WEBROOT"/
  [ -f "$WEBROOT/index.html" ] || $SUDO mv "$WEBROOT/$(basename "$idx")" "$WEBROOT/index.html"
  rm -rf "$tmpd"
  fix_site_permissions
  ok "Стрим-сайт скопирован с $STREAM_SITE_URL → $WEBROOT"
}

# Совместимость с исходным run_install/cmd_decoy.
install_decoy() { install_stream_site; }
install_decoy_builtin() { die "Случайные заглушки в этом форке отключены."; }

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
  local port="$1" url
  if [ "$port" = 443 ]; then url="https://${DOMAIN}/"; else url="https://${DOMAIN}:${port}/"; fi
  curl -ksS --max-time 12 --resolve "${DOMAIN}:${port}:127.0.0.1" \
    -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true
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
  listener_is "$BACKEND_PORT" 'rw-core' '127\.0\.0\.1:7443' &&
  listener_is "$NODE_PORT" 'rw-node'
}

show_topology() {
  ss -lntp 2>/dev/null | grep -E ":(${NODE_PORT}|${REALITY_PORT}|${BACKEND_PORT}|${CADDY_LOCAL_PORT})[[:space:]]" || true
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

warn_if_xhttp_missing() {
  listener_is "$BACKEND_PORT" 'rw-core' '127\.0\.0\.1:7443' && return 0
  warn "REALITY держит :443, но XHTTP 127.0.0.1:${BACKEND_PORT} отсутствует — Caddy оставлен живым, профиль нужно дополнить XHTTP inbound."
}

# ── Проверка бэкенда 7443 + честный вердикт (нода жива / упала / только фронт)
verify_backend() {
  printf '\n%bБэкенд ноды 127.0.0.1:%s:%b ' "$B" "$BACKEND_PORT" "$N"
  if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q "127.0.0.1:${BACKEND_PORT}"; then
    printf '%b✓ слушает%b — XHTTP-инбаунд Xray поднят.\n' "$G" "$N"
  elif [ -n "$SECRET_KEY" ] && $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$'; then
    printf '%bконтейнер поднят, инбаунд ещё не слушает%b\n' "$Y" "$N"
    warn "Это НОРМАЛЬНО до шага в панели. В Remnawave назначь ноде Config Profile с инбаундом"
    warn "VLESS+XHTTP на 127.0.0.1:${BACKEND_PORT} (путь = ${TUNNEL_PATH}, sessionIDKey/sessionKey=auth)."
    warn "Если нода серая — проверь, что порт ${NODE_PORT} открыт для сервера панели (mTLS)."
    say  "  Проверка: ${DIM}docker logs -f remnanode${N} ; ${DIM}ss -lntp | grep ${BACKEND_PORT}${N}"
  elif [ -n "$SECRET_KEY" ]; then
    printf '%b✗ контейнер ноды не работает%b\n' "$R" "$N"
    warn "SECRET_KEY ввёден, но Remnanode упал — 7443 не встанет. Частая причина: неверный/обрезанный ключ."
    say  "  Смотри: ${DIM}docker logs --tail 40 remnanode${N} ; затем ${DIM}cd $NODE_DIR && docker compose up -d${N}"
  else
    printf '%b✗ никто не слушает%b\n' "$R" "$N"
    warn "Выбран ТОЛЬКО фронт (SECRET_KEY не введён) — Caddy будет отдавать 502, пока нет ноды."
    say  "  Подними ноду: ${DIM}bash $0 install${N} (с SECRET_KEY), затем назначь Config Profile в панели."
  fi
}

# ── Домен/путь для standalone-сводки: из env, иначе из существующего Caddyfile
resolve_for_summary() {
  if [ -z "$DOMAIN" ] && [ -f "$CADDYFILE" ]; then
    DOMAIN="$(awk '/^[A-Za-z0-9].*\{[[:space:]]*$/{gsub(/[[:space:]]*\{[[:space:]]*$/,""); print $1; exit}' "$CADDYFILE" 2>/dev/null || true)"
  fi
  if [ -z "$TUNNEL_PATH" ] && [ -f "$CADDYFILE" ]; then
    TUNNEL_PATH="$(current_path)"
  fi
  [ -n "$TUNNEL_PATH" ] || TUNNEL_PATH="$(gen_path)"
}

# ── ИТОГ: «что и куда вставлять» (CDN-ресурс + хост + инбаунд Remnawave) ─────
summary() {
  local ip4; ip4="$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || true)"
  echo; line
  printf '%b%b  📋 ЧТО И КУДА ВСТАВЛЯТЬ%b   %b(домен ноды: %s · путь: %s)%b\n' "$B" "$G" "$N" "$DIM" "${DOMAIN:-—}" "${TUNNEL_PATH:-—}" "$N"
  line
  cat <<EOF

${B}Параметры этой ноды:${N}
  Домен origin (Caddy) : ${DOMAIN:-—}   ${DIM}(auto-TLS Let's Encrypt)${N}
  IP сервера           : ${ip4:-—}
  Бэкенд (Xray)        : 127.0.0.1:${BACKEND_PORT}
  Туннель-путь         : ${G}${TUNNEL_PATH:-—}${N}   ${DIM}← ОДИН и тот же в 3 местах ниже${N}
  Caddyfile            : ${CADDYFILE}

${B}① Ресурс Beeline CDN (тип «Статика»):${N}
  Источник (Адрес)         : ${DOMAIN:-<домен-ноды>}:443
  Использовать HTTPS       : ✅ ВКЛ  ·  Указать имя SNI-хоста: ✅ ${DOMAIN:-<домен-ноды>}
  Hostname к источнику     : ${DOMAIN:-<домен-ноды>}
  Кэширование              : ❌ ВЫКЛ (обязательно)
  HTTP/2                   : ✅ ВКЛ   ·   HTTP/3: ❌ ВЫКЛ
  Только современные TLS   : ✅ ВКЛ   ·   Brotli/Gzip/CORS: ❌ ВЫКЛ
  Таймауты (соед/отпр/отв) : 5 / 300 / 300
  Экспертные → Rewrite     : Откуда ${G}${TUNNEL_PATH}/${N}  →  Куда ${G}${TUNNEL_PATH}${N}   (на конечных узлах)
  Разрешённые HTTP-методы  : ${B}POST${N}  (GET/HEAD/OPTIONS разрешены всегда)
  После настройки          : полная очистка кэша ресурса

${B}② Хост в Remnawave (Хосты → создать/править):${N}
  Адрес        : <твой CDN-домен>   ${DIM}(cname вида *.a.trbcdn.net, НЕ edge-IP)${N}
  Порт         : 443
  SNI          : <твой CDN-домен>   ·   Хост: <твой CDN-домен>
  Путь         : ${G}${TUNNEL_PATH}${N}
  Security     : TLS   ·   ALPN: h2   ·   Отпечаток: ${B}firefox${N}   ${DIM}(НЕ chrome)${N}
  xHTTP extra  : ПУСТО (все extra уже в инбаунде профиля)

${B}③ Config Profile / основной XHTTP inbound:${N}
  listen 127.0.0.1 · port ${BACKEND_PORT} · network xhttp · mode packet-up · security none
  path: ${G}${TUNNEL_PATH}${N}  ·  аплинк POST(body) / даунлинк GET  ·  sessionKey/sessionIDKey: auth

${B}④ Готовые inbound для Config Profile:${N}
  XHTTP   : ${C}${XHTTP_INBOUND}${N}
  REALITY : ${C}${REALITY_INBOUND}${N}
  Оба     : ${C}${PROFILE_INBOUNDS}${N}
  В них уже стоят домен ${DOMAIN:-—}, путь ${TUNNEL_PATH:-—}, Origin/Referer и target 127.0.0.1:${CADDY_LOCAL_PORT}.
  Caddy topology guard выбирает режим по владельцу TCP/443: rw-core держит :443 → Caddy 127.0.0.1:${CADDY_LOCAL_PORT}; rw-core нет → публичный Caddy :443.
  Отсутствие XHTTP 127.0.0.1:${BACKEND_PORT} не останавливает Caddy, но означает неполный Config Profile.

${B}Проверка:${N} нода 🟢 в панели → ss -lntp | grep ${BACKEND_PORT} (LISTEN) → подключись клиентом (Happ/INCY).
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
    warn_if_xhttp_missing
    ok "Схема выбрана по владельцу TCP/443: rw-core → :443; Caddy → 127.0.0.1:${CADDY_LOCAL_PORT}."
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
      warn_if_xhttp_missing
      ok "Схема выбрана по владельцу TCP/443: rw-core → :443; Caddy → 127.0.0.1:${CADDY_LOCAL_PORT}."
      return 0
    fi
    warn "rw-core не занял TCP/443 — возвращаю публичный Caddy."
  fi

  restart_caddy_for_owner || die "Не удалось запустить Caddy в публичном режиме."
  verify_site_port "$REALITY_PORT"
  if final_topology_ready; then
    ok "Профиль активен: rw-core → :443 и 127.0.0.1:${BACKEND_PORT}; Caddy → 127.0.0.1:${CADDY_LOCAL_PORT}."
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
  # (новый случайный путь рассинхронизирует ноду с CDN Rewrite и хостом панели → трафик встанет).
  # reinstall сначала сносит Caddyfile через clean_node, поэтому там guard не мешает (файла нет → новый путь).
  if [ -z "$TUNNEL_PATH" ] && [ -f "$CADDYFILE" ] && [ "$INTERACTIVE" = 1 ]; then
    _cur="$(current_path)"
    if [ -n "$_cur" ]; then
      warn "Найдена прошлая установка. Текущий туннель-путь: ${G}${_cur}${N}"
      warn "Новый путь рассинхронизирует ноду с CDN Rewrite и хостом панели — трафик встанет, пока не обновишь их."
      printf 'Оставить ТЕКУЩИЙ путь? [Y/n]  (n = сгенерировать новый) '; read -r _keep <"$TTY" || true
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
  if [ -z "${GHOST_NONINTERACTIVE:-}" ]; then
    printf 'Продолжить установку? [Y/n] '; read -r yn <"$TTY" || true
    case "${yn:-Y}" in [Nn]*) die "Отменено." ;; esac
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
  say "  XHTTP JSON  : ${C}${XHTTP_INBOUND}${N}"
  say "  REALITY JSON: ${C}${REALITY_INBOUND}${N}"
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
  $SUDO docker rm -f remnanode 2>/dev/null || true
  $SUDO rm -rf "$NODE_DIR"
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
  if [ -z "${GHOST_NONINTERACTIVE:-}" ]; then
    printf 'Продолжить? [y/N] '; read -r yn <"$TTY" || true
    case "${yn:-N}" in [Yy]*) : ;; *) die "Отменено." ;; esac
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
  say  "   ${DIM}•${N} CDN Rewrite: Откуда ${G}${p}/${N} → Куда ${G}${p}${N}"
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
    printf 'Новый XHTTP-путь: '
    read -r requested <"$TTY" || true
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
    write_xhttp_inbound
    [ -s "$REALITY_INBOUND" ] && write_profile_bundle
  fi
  ok "XHTTP-путь изменён: $old → $requested"
  warn "Теперь поставь тот же путь в Config Profile, CDN Rewrite и хосте Remnawave."
}

# ── Статус сервисов ──────────────────────────────────────────────────────────
cmd_status() {
  banner
  printf '  %bCaddy%b     : ' "$B" "$N"
  $SUDO systemctl is-active caddy 2>/dev/null || echo "не активен"
  printf '  %bRemnanode%b : ' "$B" "$N"
  if $SUDO docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep '^remnanode' ; then :; else echo "не запущен"; fi
  printf '  %bПорты%b     :\n' "$B" "$N"
  ss -lntp 2>/dev/null | grep -E ":80 |:443 |127.0.0.1:${BACKEND_PORT}|127.0.0.1:${CADDY_LOCAL_PORT}|:${NODE_PORT} " | sed 's/^/    /' || echo "    (нет слушателей 80/443/${BACKEND_PORT}/${CADDY_LOCAL_PORT}/${NODE_PORT})"
  if [ -f "$CADDYFILE" ]; then
    printf '  %bПуть в Caddyfile%b : %s\n' "$B" "$N" "$(current_path)"
  fi
}

# ── Глубокая диагностика: [A] сбор → [B] вердикты → [C] CDN → [D] итог ────────
cmd_diagnose() {
  set +e; trap - ERR   # диагностика намеренно запускает падающие пробы
  banner
  local path; path="$(current_path)"; [ -n "$path" ] || path="—"
  printf '  %b🩺 Диагностика узла%b  %b(бэкенд 127.0.0.1:%s · путь %s)%b\n\n' "$B" "$N" "$DIM" "$BACKEND_PORT" "$path" "$N"

  line; printf '%b  [A] Автосбор состояния%b\n' "$B" "$N"; line
  printf '%b$ systemctl is-active caddy%b  → %s\n' "$C" "$N" "$($SUDO systemctl is-active caddy 2>/dev/null || echo нет)"
  printf '%b$ docker ps -a (remnanode)%b\n' "$C" "$N"; $SUDO docker ps -a --filter name=remnanode --format '  {{.Names}}\t{{.Status}}' 2>/dev/null || echo "  (docker нет / контейнера нет)"
  printf '%b$ ss -lntp (80/443/%s/%s)%b\n' "$C" "$BACKEND_PORT" "$NODE_PORT" "$N"; ss -lntp 2>/dev/null | grep -E ":80 |:443 |:${BACKEND_PORT} |:${NODE_PORT} " | sed 's/^/  /' || echo "  (нет)"
  printf '%b$ docker logs remnanode --tail 12%b\n' "$C" "$N"; $SUDO docker logs remnanode --tail 12 2>&1 | sed -E 's/(token=)[^&[:space:]]+/\1<REDACTED>/Ig; s/(SECRET_KEY[=:][[:space:]]*)[^[:space:]]+/\1<REDACTED>/Ig' | sed 's/^/  /' || echo "  (контейнера нет)"
  echo

  line; printf '%b  [B] Диагноз по компонентам%b\n' "$B" "$N"; line
  local fail=0
  _diag(){ printf '  %b▸ %s%b\n    %bпричина:%b %s\n    %bфикс:%b    %s\n\n' "$R" "$1" "$N" "$Y" "$N" "$2" "$G" "$N" "$3"; fail=$((fail+1)); }

  if ! $SUDO systemctl is-active caddy >/dev/null 2>&1; then
    _diag "Caddy НЕ запущен" "битый Caddyfile или занят порт 80/443" "caddy validate --config $CADDYFILE ; ss -lntp | grep -E ':80|:443' ; systemctl restart caddy"
  fi
  if ! $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$'; then
    if $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$'; then
      _diag "Remnanode УПАЛ (есть в ps -a, нет в ps)" "неверный/обрезанный SECRET_KEY или нет сети до панели" "docker logs --tail 50 remnanode ; проверь SECRET_KEY в $NODE_DIR/docker-compose.yml (только значение) ; cd $NODE_DIR && docker compose up -d"
    else
      _diag "Remnanode ОТСУТСТВУЕТ" "нода не разворачивалась на этом сервере" "bash $0 install (введи SECRET_KEY)"
    fi
  fi
  if ! ss -lntp 2>/dev/null | grep -q "127.0.0.1:${BACKEND_PORT}"; then
    _diag "127.0.0.1:${BACKEND_PORT} НЕ слушает → Caddy отдаёт 502" "инбаунд Xray не поднят: нода без Config Profile ИЛИ порт ${NODE_PORT} закрыт для панели" "Remnawave → Профили → создай/привяжи профиль ноде (path=${path}, listen 127.0.0.1:${BACKEND_PORT}) ; открой порт ${NODE_PORT} для панели ; docker logs -f remnanode"
  fi
  if [ ! -f "$CADDYFILE" ]; then
    _diag "Caddyfile отсутствует" "фронт не устанавливался" "bash $0 install"
  fi

  line; printf '%b  [C] CDN-уровень (с ноды НЕ тестируется достоверно)%b\n' "$B" "$N"; line
  say "  ${Y}Не тестируй CDN-домен curl'ом С НОДЫ${N} — запрос уходит в кривой edge и врёт."
  say "  Проверяй пути ЛОКАЛЬНО (Caddy → Xray), CDN — с клиента:"
  say "   ${DIM}живой путь${N}  : curl -I \"https://${DOMAIN:-<домен>}${path}?auth=test\"  → 400 + заголовок x-api-key"
  say "   ${DIM}мёртвый путь${N}: тот же curl на ЧУЖОЙ путь           → 200 + HTML стрим-сайта"
  echo
  line; printf '%b  [D] Итог%b\n' "$B" "$N"; line
  if [ "$fail" -eq 0 ]; then say "  ${G}Локальный узел здоров.${N} Если клиент не работает — сверь путь во всех местах и настройку CDN-ресурса (блок C)."
  else say "  ${Y}Проблем на узле: ${fail}.${N} Чини по подсказкам (фикс) сверху вниз и запусти диагностику снова."; fi
  say "  ${C}📖 info.ghostos.space → гайд «Beeline CDN + XHTTP»${N}"
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
REALITY_TARGET=127.0.0.1:$CADDY_LOCAL_PORT
EOF
  chmod 600 "$REALITY_ENV"
  unset private public raw
  ok "Ключи REALITY сохранены с правами 600 → $REALITY_ENV"
}

write_reality_inbound() {
  # shellcheck disable=SC1090
  . "$REALITY_ENV"
  umask 077
  cat > "$REALITY_INBOUND" <<EOF
{
  "tag": "Bee-Direct-Reality",
  "listen": "0.0.0.0",
  "port": $REALITY_PORT,
  "protocol": "vless",
  "settings": {
    "clients": [],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "raw",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "target": "127.0.0.1:$CADDY_LOCAL_PORT",
      "xver": 0,
      "serverNames": ["$DOMAIN"],
      "privateKey": "$REALITY_PRIVATE_KEY",
      "shortIds": ["$REALITY_SHORT_ID"]
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"],
    "metadataOnly": false,
    "routeOnly": true
  }
}
EOF
  chmod 600 "$REALITY_INBOUND"
  ok "Inbound JSON для Config Profile → $REALITY_INBOUND"
}

write_xhttp_inbound() {
  local slug tag cookie
  slug="${DOMAIN%%.*}"
  slug="$(printf '%s' "$slug" | sed -E 's/[^A-Za-z0-9_-]+/-/g')"
  tag="Bee-CDN-${slug^}"
  cookie="$(openssl rand -hex 16)"
  umask 077
  cat > "$XHTTP_INBOUND" <<EOF
{
  "tag": "$tag",
  "port": $BACKEND_PORT,
  "listen": "127.0.0.1",
  "protocol": "vless",
  "settings": {"clients": [], "decryption": "none"},
  "sniffing": {
    "enabled": true,
    "routeOnly": true,
    "destOverride": ["http", "tls", "quic"]
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "none",
    "xhttpSettings": {
      "mode": "packet-up",
      "path": "$TUNNEL_PATH",
      "extra": {
        "mode": "packet-up",
        "path": "$TUNNEL_PATH",
        "xmux": {"maxConcurrency": "1"},
        "seqKey": "chunk_id",
        "headers": {
          "Accept": "*/*",
          "Cookie": "session_id=$cookie",
          "Origin": "https://$DOMAIN/",
          "Referer": "https://$DOMAIN/",
          "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:151.0) Gecko/20100101 Firefox/151.0",
          "Sec-Fetch-Dest": "empty",
          "Sec-Fetch-Mode": "cors",
          "Sec-Fetch-Site": "same-origin",
          "Accept-Language": "ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7"
        },
        "sessionKey": "auth",
        "sessionIDKey": "auth",
        "seqPlacement": "query",
        "sessionPlacement": "query",
        "sessionIDPlacement": "query",
        "sessionIDTable": "Base62",
        "sessionIDLength": "16-32",
        "uplinkHTTPMethod": "POST",
        "downloadHTTPMethod": "GET",
        "uplinkDataPlacement": "body",
        "xPaddingBytes": "50-150",
        "xPaddingHeader": "X-Api-Key",
        "xPaddingMethod": "tokenish",
        "xPaddingObfsMode": true,
        "xPaddingPlacement": "header",
        "noSSEHeader": true,
        "noGRPCHeader": true,
        "scMaxBufferedPosts": 100,
        "scMaxEachPostBytes": 3000000,
        "scMinPostsIntervalMs": "5-10",
        "serverMaxHeaderBytes": 32768
      },
      "noSSEHeader": true,
      "noGRPCHeader": true,
      "scMaxBufferedPosts": 100,
      "scMaxEachPostBytes": 3000000,
      "scMaxConcurrentPosts": 10,
      "scMinPostsIntervalMs": 5,
      "serverMaxHeaderBytes": 32768
    }
  }
}
EOF
  chmod 600 "$XHTTP_INBOUND"
  ok "XHTTP inbound JSON → $XHTTP_INBOUND"
}

write_profile_bundle() {
  umask 077
  {
    printf '{\n  "inbounds": [\n'
    sed 's/^/    /' "$XHTTP_INBOUND"
    printf '    ,\n'
    sed 's/^/    /' "$REALITY_INBOUND"
    printf '  ]\n}\n'
  } > "$PROFILE_INBOUNDS"
  chmod 600 "$PROFILE_INBOUNDS"
  ok "Оба inbound одним файлом → $PROFILE_INBOUNDS"
}

prepare_profile_files() {
  generate_reality_material
  write_caddyfile_reality
  write_reality_inbound
  write_xhttp_inbound
  write_profile_bundle
}

cmd_reality_prepare() {
  banner
  resolve_existing
  [ -s "$WEBROOT/index.html" ] || install_stream_site
  fix_site_permissions
  [ -s "$CADDY_PUBLIC" ] || $SUDO cp -a "$CADDYFILE" "$CADDY_PUBLIC"
  prepare_profile_files
  echo; line
  say "${B}Подготовлено без переключения портов.${N}"
  say "  Готовый XHTTP inbound : ${C}${XHTTP_INBOUND}${N}"
  say "  Готовый REALITY inbound: ${C}${REALITY_INBOUND}${N}"
  say "  Оба объекта вместе     : ${C}${PROFILE_INBOUNDS}${N}"
  say "  В JSON уже стоят правильные DOMAIN, Origin, Referer, target=127.0.0.1:${CADDY_LOCAL_PORT} и выбранный XHTTP-путь."
  say "  Если Caddy ещё публично слушает :443, выполни после сохранения профиля: ${C}${SCRIPT_INSTALL_PATH} reality-enable${N}"
  line
}

reality_enable_impl() {
  resolve_existing
  [ -s "$CADDY_REALITY" ] || prepare_profile_files
  $SUDO caddy validate --config "$CADDY_REALITY" --adapter caddyfile || die "Caddyfile REALITY невалиден."
  [ -s "$CADDY_PUBLIC" ] || $SUDO cp -a "$CADDYFILE" "$CADDY_PUBLIC"
  fix_site_permissions

  if rw_core_on_443; then
    restart_caddy_for_owner || die "rw-core держит :443, но Caddy не удалось запустить на 127.0.0.1:${CADDY_LOCAL_PORT}."
    verify_site_port "$REALITY_PORT"
    if final_topology_ready; then
      ok "Готово: rw-core → :443; Caddy → 127.0.0.1:${CADDY_LOCAL_PORT}; XHTTP → 127.0.0.1:${BACKEND_PORT}"
    else
      warn_if_xhttp_missing
      ok "Caddy работает через REALITY fallback; отсутствие XHTTP 127.0.0.1:${BACKEND_PORT} не останавливает Caddy."
    fi
    show_topology
    return 0
  fi

  warn "rw-core пока не держит :443 — временно останавливаю Caddy, чтобы REALITY мог занять порт."
  $SUDO systemctl stop caddy 2>/dev/null || true
  restart_remnanode_if_present
  log "Жду rw-core на :443; Caddy будет запущен через topology guard..."
  local i
  for i in $(seq 1 120); do
    if rw_core_on_443; then
      restart_caddy_for_owner || die "rw-core занял :443, но Caddy не удалось запустить на 127.0.0.1:${CADDY_LOCAL_PORT}."
      if check_site_port "$REALITY_PORT" 8; then
        warn_if_xhttp_missing
        ok "Готово: режим выбран по владельцу TCP/443; Caddy не зависит от наличия XHTTP ${BACKEND_PORT}."
        show_topology
        return 0
      fi
      warn "Порты поднялись, но сайт через REALITY fallback не отвечает."
      show_topology
      $SUDO docker logs --since 5m remnanode 2>&1 | tr -d '\000' | \
        sed -E 's/(token=)[^&[:space:]]+/\1<REDACTED>/Ig; s/("privateKey"[[:space:]]*:[[:space:]]*")[^"]+/\1<REDACTED>/Ig' | tail -60 || true
      die "Проверь target=127.0.0.1:${CADDY_LOCAL_PORT} и serverNames=${DOMAIN} в REALITY inbound."
    fi
    sleep 1
  done
  warn "rw-core не занял :443; откатываю публичный Caddy."
  restart_caddy_for_owner || true
  verify_site_port 443 || true
  $SUDO docker logs --since 5m remnanode 2>&1 | tr -d '\000' | \
    sed -E 's/(token=)[^&[:space:]]+/\1<REDACTED>/Ig; s/("privateKey"[[:space:]]*:[[:space:]]*")[^"]+/\1<REDACTED>/Ig' | tail -60 || true
  die "Reality inbound не запустился. Проверь JSON профиля."
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
  printf '  %-24s %s\n' 'XHTTP inbound JSON:' "$XHTTP_INBOUND"
  printf '  %-24s %s\n' 'REALITY inbound JSON:' "$REALITY_INBOUND"
  printf '  %-24s %s\n' 'Оба inbound:' "$PROFILE_INBOUNDS"
  printf '  %-24s %s\n' 'REALITY ключи:' "$REALITY_ENV"
  printf '  %-24s %s\n' 'Caddy public:' "$CADDY_PUBLIC"
  printf '  %-24s %s\n' 'Caddy reality:' "$CADDY_REALITY"
  printf '  %-24s %s\n' 'Стрим-сайт:' "$WEBROOT"
  echo
  say "  Секретные значения намеренно не выводятся."
  ss -lntp 2>/dev/null | grep -E ":443 |127.0.0.1:${BACKEND_PORT}|127.0.0.1:${CADDY_LOCAL_PORT}" | sed 's/^/  /' || true
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
    if ss -lntp 2>/dev/null | grep -q "127.0.0.1:${BACKEND_PORT}"; then
      ok "Сайт и XHTTP работают; REALITY inbound на 443 в профиле пока не активен."
    else
      warn "Сайт исправлен. XHTTP/REALITY появятся после применения корректного Config Profile."
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
  printf '   %b[6]%b  📋  Что и куда вставлять    %b— сводка для CDN и панели Remnawave%b\n' "$BL" "$N" "$DIM" "$N"
  printf '   %b[7]%b  🩺  Диагностика            %b— симптом → причина → фикс%b\n' "$M" "$N" "$DIM" "$N"
  printf '   %b[8]%b  📊  Статус сервисов        %b— caddy / remnanode / порты%b\n' "$Y" "$N" "$DIM" "$N"
  printf '   %b[9]%b  🔐  Подготовить REALITY     %b— XHTTP+REALITY JSON + Caddy:8443%b\n' "$C" "$N" "$DIM" "$N"
  printf '   %b[10]%b ⚡  Включить REALITY        %b— переключить один внешний TCP/443%b\n' "$G" "$N" "$DIM" "$N"
  printf '   %b[11]%b ↩   Отключить REALITY       %b— вернуть публичный Caddy:443%b\n' "$Y" "$N" "$DIM" "$N"
  printf '   %b[12]%b ℹ   Файлы REALITY           %b— пути без вывода ключей%b\n' "$BL" "$N" "$DIM" "$N"
  printf '   %b[13]%b 🛠   Исправить текущую ноду %b— сайт, права и конфликт Caddy/REALITY%b\n' "$G" "$N" "$DIM" "$N"
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
    12) cmd_reality_info ;;
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
    clean|uninstall)       clean_node ;;
    menu|"")               menu ;;
    -h|--help|help)        sed -n '18,43p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "Неизвестная команда: $cmd (см. --help)" ;;
  esac
}

main "$@"
