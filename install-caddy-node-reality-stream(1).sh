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
#  install-caddy-node-reality-stream.sh — Caddy + стрим-сайт для основной
#  XHTTP-ноды за Beeline CDN и подготовка второго VLESS RAW REALITY Vision
#  на том же внешнем TCP/443. Опционально поднимает Remnanode.
#
#  Запуск без аргументов открывает МЕНЮ. Также доступны подкоманды:
#    install | --auto   полная установка (нода по SECRET_KEY + Caddy)
#    front-only         только фронт Caddy (ноду поднять отдельно)
#    reinstall          снос всего локального + установка заново
#    path               сгенерировать/показать туннель-путь
#    summary            «что и куда вставлять» (CDN + панель Remnawave)
#    diagnose | diag    глубокая диагностика (симптом → причина → фикс)
#    status             статус сервисов (caddy / remnanode / порты)
#    stream             установить/обновить стрим-сайт
#    reality-prepare    подготовить ключи, inbound JSON и локальный Caddy:8443
#    reality-enable     переключить Caddy на 127.0.0.1:8443 и ждать rw-core:443
#    reality-disable    вернуть публичный Caddy:443 после удаления Reality inbound
#    reality-info       показать пути к подготовленным файлам без вывода ключей
#    clean | uninstall  снести ноду и конфиг Caddy
#    menu               показать меню (по умолчанию)
#    -h | --help        эта справка
#
#  Неинтерактивно:
#    EMAIL=you@mail.com DOMAIN=node.example.net SECRET_KEY=... \
#      STREAM_SITE_URL=https://est.remna.2rdp.ru/ bash $0 --auto
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
WEBROOT=/var/www/mstream
STREAM_SITE_URL="${STREAM_SITE_URL:-https://est.remna.2rdp.ru/}"
STREAM_SITE_ARCHIVE="${STREAM_SITE_ARCHIVE:-}"
STREAM_HEALTH_UPSTREAM="${STREAM_HEALTH_UPSTREAM:-https://stream.deepbeat.ru:8443/health}"

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
    ok "Ключ принят: ${#SECRET_KEY} символов (…${SECRET_KEY: -4})"
    [ "${#SECRET_KEY}" -ge 40 ] || warn "Ключ короткий (${#SECRET_KEY} симв.) — возможно, вставился обрезанным (обычно длиннее 100)."
  fi
  [ -n "$TUNNEL_PATH" ] || TUNNEL_PATH="$(gen_path)"
  : # стрим-сайт фиксированный; каталог случайных заглушек не используется
}

# ── Установка ноды Remnanode (Docker) ────────────────────────────────────────
install_node() {
  [ -n "$SECRET_KEY" ] || { warn "SECRET_KEY пуст — ноду не ставлю (только фронт)."; return 0; }
  log "Docker + Remnanode..."
  if ! command -v docker >/dev/null 2>&1; then
    log "Ставлю Docker (get.docker.com)..."; curl -fsSL https://get.docker.com | $SUDO sh
  fi
  $SUDO mkdir -p "$NODE_DIR"
  $SUDO tee "$NODE_DIR/docker-compose.yml" >/dev/null <<NODE_EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    environment:
      NODE_PORT: "${NODE_PORT}"
      SECRET_KEY: "${SECRET_KEY}"
NODE_EOF
  ( cd "$NODE_DIR" && $SUDO docker compose up -d ) || die "Не удалось поднять Remnanode (docker compose)."
  sleep 4
  if $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$'; then
    ok "Remnanode запущен и держится → $NODE_DIR"
  else
    warn "Remnanode стартовал, но сейчас НЕ работает (крэш-луп). Почти всегда причина — неверный/обрезанный SECRET_KEY."
    say  "  Логи (последние 20 строк):"
    $SUDO docker logs --tail 20 remnanode 2>&1 | sed 's/^/    /' || true
    say  "  Скопируй ключ заново (только значение) в $NODE_DIR/docker-compose.yml и: ${DIM}cd $NODE_DIR && docker compose up -d${N}"
  fi
  # порт 2222 — по нему панель ходит к ноде (mTLS); закрыт → нода серая
  if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -qi "Status: active"; then
    $SUDO ufw allow "${NODE_PORT}/tcp" >/dev/null 2>&1 && ok "UFW: открыт порт $NODE_PORT (панель ↔ нода)"
  fi
  warn "Порт $NODE_PORT должен быть доступен серверу панели Remnawave. Если у хостера security-group — открой $NODE_PORT и там."
}

# ── Установка Caddy (идемпотентно) ───────────────────────────────────────────
install_caddy() {
  if command -v caddy >/dev/null 2>&1; then ok "Caddy уже установлен: $(caddy version 2>/dev/null | head -1)"; return 0; fi
  log "Установка Caddy из репозитория Cloudsmith..."
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update -y
  $SUDO apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | $SUDO gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | $SUDO tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y caddy
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
    ok "Стрим-сайт установлен из архива → $WEBROOT"
    return 0
  fi

  if [ -s "$WEBROOT/index.html" ] && [ "${FORCE_STREAM_REFRESH:-0}" != 1 ]; then
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
  ok "Стрим-сайт скопирован с $STREAM_SITE_URL → $WEBROOT"
}

# Совместимость с исходным run_install/cmd_decoy.
install_decoy() { install_stream_site; }
install_decoy_builtin() { die "Случайные заглушки в этом форке отключены."; }

# ── Валидация + запуск Caddy ─────────────────────────────────────────────────
start_caddy() {
  log "Проверка и запуск Caddy..."
  $SUDO caddy fmt --overwrite "$CADDYFILE" || true
  $SUDO caddy validate --config "$CADDYFILE" --adapter caddyfile || die "Caddyfile не прошёл валидацию — смотри вывод выше."
  $SUDO systemctl enable caddy >/dev/null 2>&1 || true
  $SUDO systemctl restart caddy || true
  sleep 1
  if $SUDO systemctl is-active --quiet caddy; then
    ok "Caddy активен и запущен"
  else
    warn "Caddy не активен — смотри: journalctl -u caddy -e --no-pager"
    $SUDO systemctl status caddy --no-pager -l 2>/dev/null | tail -n 20 || true
  fi
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

${B}④ Второй прямой inbound REALITY:${N}
  Выполни: ${C}bash $0 reality-prepare${N}
  Затем добавь JSON из ${C}${REALITY_INBOUND}${N} в тот же Config Profile.
  Для Reality-хоста/клиента: port 443 · network raw · flow xtls-rprx-vision.

${B}Проверка:${N} нода 🟢 в панели → ss -lntp | grep ${BACKEND_PORT} (LISTEN) → подключись клиентом (Happ/INCY).
EOF
  line
}

# ── Полная установка ─────────────────────────────────────────────────────────
run_install() {
  local mode="${1:-ask}" _cur="" _keep=""   # ask|front
  banner
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
  install_node
  install_caddy
  write_caddyfile
  install_stream_site
  start_caddy
  printf '\n%b%bФронт Caddy + стрим-сайт готовы.%b\n' "$G" "$B" "$N"
  say "  Домен       : ${C}${DOMAIN}${N}"
  say "  Туннель-путь: ${G}${TUNNEL_PATH}${N}  ${DIM}(вставь в инбаунд ноды, в CDN Rewrite и в хост панели)${N}"
  printf '%bПорты 80 и 443 должны быть открыты для выпуска Let'\''s Encrypt.%b\n' "$Y" "$N"
  verify_backend
  summary
}

# ── Снос всего локального (нода + конфиг Caddy + стрим-сайт) ────────────────────
clean_node() {
  log "Снос ноды и фронта Caddy..."
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
  printf '%b$ docker logs remnanode --tail 12%b\n' "$C" "$N"; $SUDO docker logs remnanode --tail 12 2>&1 | sed 's/^/  /' || echo "  (контейнера нет)"
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
  [ -x "$core" ] || die "rw-core не найден; сначала установи/запусти Remnanode."
  raw="$($SUDO "$core" x25519 2>/dev/null)" || die "rw-core x25519 завершился ошибкой."
  private="$(printf '%s\n' "$raw" | sed -nE 's/^[[:space:]]*(PrivateKey|Private key):[[:space:]]*//p' | head -1)"
  public="$(printf '%s\n' "$raw" | sed -nE 's/^[[:space:]]*(Password|PublicKey|Public key):[[:space:]]*//p' | head -1)"
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

cmd_reality_prepare() {
  banner
  resolve_existing
  [ -s "$WEBROOT/index.html" ] || install_stream_site
  [ -s "$CADDY_PUBLIC" ] || $SUDO cp -a "$CADDYFILE" "$CADDY_PUBLIC"
  generate_reality_material
  write_caddyfile_reality
  write_reality_inbound
  echo; line
  say "${B}Подготовлено без переключения портов.${N}"
  say "  1. Добавь объект из ${C}${REALITY_INBOUND}${N} вторым inbound в Config Profile ноды."
  say "  2. Для пользователей Reality укажи flow=${G}xtls-rprx-vision${N}."
  say "  3. Сразу после сохранения профиля выполни: ${C}bash $0 reality-enable${N}"
  say "  Значения для клиента находятся в ${C}${REALITY_ENV}${N}; скрипт их в терминал не печатает."
  line
}

cmd_reality_enable() {
  banner
  resolve_existing
  [ -s "$CADDY_REALITY" ] || die "Сначала выполни reality-prepare."
  $SUDO caddy validate --config "$CADDY_REALITY" --adapter caddyfile || die "Caddyfile REALITY невалиден."
  [ -s "$CADDY_PUBLIC" ] || $SUDO cp -a "$CADDYFILE" "$CADDY_PUBLIC"
  $SUDO install -o root -g root -m 0644 "$CADDY_REALITY" "$CADDYFILE"
  $SUDO systemctl restart caddy || true
  sleep 2
  if ! ss -lntp 2>/dev/null | grep -q "127.0.0.1:${CADDY_LOCAL_PORT}"; then
    warn "Caddy не поднялся на 127.0.0.1:${CADDY_LOCAL_PORT}; откатываю."
    $SUDO install -o root -g root -m 0644 "$CADDY_PUBLIC" "$CADDYFILE"
    $SUDO systemctl restart caddy || true
    die "Переключение отменено."
  fi
  log "Caddy локально готов. Жду rw-core на внешнем TCP/443..."
  local i
  for i in $(seq 1 60); do
    if ss -lntp 2>/dev/null | grep -E ':443[[:space:]]' | grep -q 'rw-core'; then
      ok "Готово: rw-core → :443; Caddy → 127.0.0.1:${CADDY_LOCAL_PORT}; XHTTP → 127.0.0.1:${BACKEND_PORT}"
      return 0
    fi
    sleep 1
  done
  warn "rw-core не занял :443 за 60 секунд; откатываю публичный Caddy."
  $SUDO install -o root -g root -m 0644 "$CADDY_PUBLIC" "$CADDYFILE"
  $SUDO systemctl restart caddy || true
  die "Проверь, что Reality inbound сохранён в профиле и нода получила конфиг."
}

cmd_reality_disable() {
  banner
  if ss -lntp 2>/dev/null | grep -E ':443[[:space:]]' | grep -q 'rw-core'; then
    die "Сначала удали/отключи Reality inbound в Config Profile и дождись освобождения :443."
  fi
  [ -s "$CADDY_PUBLIC" ] || die "Не найден $CADDY_PUBLIC"
  $SUDO install -o root -g root -m 0644 "$CADDY_PUBLIC" "$CADDYFILE"
  $SUDO caddy validate --config "$CADDYFILE" --adapter caddyfile || die "Публичный Caddyfile невалиден."
  $SUDO systemctl restart caddy
  ok "Возвращён публичный Caddy на :443."
}

cmd_reality_info() {
  banner
  printf '  %-24s %s\n' 'REALITY inbound JSON:' "$REALITY_INBOUND"
  printf '  %-24s %s\n' 'REALITY ключи:' "$REALITY_ENV"
  printf '  %-24s %s\n' 'Caddy public:' "$CADDY_PUBLIC"
  printf '  %-24s %s\n' 'Caddy reality:' "$CADDY_REALITY"
  printf '  %-24s %s\n' 'Стрим-сайт:' "$WEBROOT"
  echo
  say "  Секретные значения намеренно не выводятся."
  ss -lntp 2>/dev/null | grep -E ":443 |127.0.0.1:${BACKEND_PORT}|127.0.0.1:${CADDY_LOCAL_PORT}" | sed 's/^/  /' || true
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
  printf '   %b[9]%b  🔐  Подготовить REALITY     %b— ключи + inbound JSON + Caddy:8443%b\n' "$C" "$N" "$DIM" "$N"
  printf '   %b[10]%b ⚡  Включить REALITY        %b— переключить один внешний TCP/443%b\n' "$G" "$N" "$DIM" "$N"
  printf '   %b[11]%b ↩   Отключить REALITY       %b— вернуть публичный Caddy:443%b\n' "$Y" "$N" "$DIM" "$N"
  printf '   %b[12]%b ℹ   Файлы REALITY           %b— пути без вывода ключей%b\n' "$BL" "$N" "$DIM" "$N"
  printf '   %b[13]%b 🧹  Снести всё (clean)      %b— удалить ноду и конфиг Caddy%b\n' "$R" "$N" "$DIM" "$N"
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
    13) clean_node ;;
    0|"") exit 0 ;;
    *) die "Неизвестный пункт: $choice" ;;
  esac
}

# ── Точка входа ──────────────────────────────────────────────────────────────
main() {
  local cmd="${1:-menu}"
  case "$cmd" in
    install|--auto|auto)   run_install ask ;;
    front-only|front)      run_install front ;;
    reinstall)             run_reinstall ;;
    path|gen-path)         cmd_path ;;
    summary|info)          resolve_for_summary; summary ;;
    diagnose|diag)         cmd_diagnose ;;
    status)                cmd_status ;;
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
