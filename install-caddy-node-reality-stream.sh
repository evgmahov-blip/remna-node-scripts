#!/usr/bin/env bash
set -Eeo pipefail

REPO_REF=32bdefa2872aef9c59fd3af99ea106773a7e2530
REPO_RAW="https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/${REPO_REF}"
CORE_BLOB_SHA=a9074d627869935311669cf23f417d913b84a4e6
TELEMT_BLOB_SHA=51604bcdd1435f2870b3428ed81b46c8389fdb8c
PROTECTION_BLOB_SHA=9185f9723d959250a5ee766b0ff71e0a977a1982
REMNA_NODE_IMAGE="${REMNA_NODE_IMAGE:-remnawave/node:3.4.1}"
INSTALL_DIR=/opt/remna-node-scripts
SELF="$INSTALL_DIR/install-caddy-node-reality-stream.sh"
CORE="$INSTALL_DIR/install-caddy-node-reality-stream-core.sh"
TELEMT_HELPER="$INSTALL_DIR/telemt-manager.sh"
PROTECTION_HELPER="$INSTALL_DIR/protection-manager.sh"
NODE_DIR=/opt/remnanode
NODE_COMPOSE="$NODE_DIR/docker-compose.yml"
NODE_ENV="$NODE_DIR/.env"
CADDYFILE=/etc/caddy/Caddyfile
CADDY_PUBLIC=/etc/caddy/Caddyfile.public
CADDY_REALITY=/etc/caddy/Caddyfile.reality
PANEL_CONFIG=/etc/telemt-panel/config.toml
HANDOFF_SERVICE=/etc/systemd/system/remna-reality-handoff.service
HANDOFF_TIMER=/etc/systemd/system/remna-reality-handoff.timer
HANDOFF_COOLDOWN=/run/remna-reality-handoff.cooldown
HANDOFF_COOLDOWN_SECONDS=${HANDOFF_COOLDOWN_SECONDS:-300}
STREAM_SOURCES=(
  "https://rustream.remna.space"
  "https://est.remna.2rdp.ru"
  "https://nl.remna.2rdp.ru"
)

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
TTY=/dev/tty; { [ -r "$TTY" ] && [ -w "$TTY" ]; } || TTY=/dev/stdin
say(){ printf '%s\n' "$*"; }
ok(){ printf '✓ %s\n' "$*"; }
warn(){ printf '! %s\n' "$*" >&2; }
die(){ printf '✗ %s\n' "$*" >&2; exit 1; }

ensure_self(){
  local current
  current="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  [ "$current" = "$SELF" ] && return 0
  $SUDO install -d -m 0755 "$INSTALL_DIR"
  $SUDO install -m 0700 "$current" "$SELF"
}

git_blob_sha(){
  local file="$1" size
  command -v sha1sum >/dev/null 2>&1 || return 1
  size="$(wc -c <"$file" | tr -d '[:space:]')"
  { printf 'blob %s\000' "$size"; cat "$file"; } | sha1sum | awk '{print $1}'
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

ensure_core(){
  $SUDO install -d -m 0755 "$INSTALL_DIR"
  if download_checked "$REPO_RAW/install-caddy-node-reality-stream-core.sh" "$CORE_BLOB_SHA" "$CORE"; then return 0; fi
  verified_script "$CORE" "$CORE_BLOB_SHA" && { warn "GitHub недоступен — использую локальный core с ожидаемым blob SHA."; return 0; }
  die "Не удалось получить рабочий core-скрипт."
}

ensure_telemt_helper(){
  if download_checked "$REPO_RAW/telemt-manager.sh" "$TELEMT_BLOB_SHA" "$TELEMT_HELPER"; then return 0; fi
  verified_script "$TELEMT_HELPER" "$TELEMT_BLOB_SHA" && { warn "GitHub недоступен — использую локальный Telemt helper с ожидаемым blob SHA."; return 0; }
  die "Не удалось получить Telemt helper."
}

ensure_protection_helper(){
  if download_checked "$REPO_RAW/protection-manager.sh" "$PROTECTION_BLOB_SHA" "$PROTECTION_HELPER"; then return 0; fi
  verified_script "$PROTECTION_HELPER" "$PROTECTION_BLOB_SHA" && { warn "GitHub недоступен — использую локальный protection helper с ожидаемым blob SHA."; return 0; }
  die "Не удалось получить protection-manager.sh."
}

choose_stream_source(){
  local src tmp
  [ -n "${STREAM_SITE_URL:-}" ] && { printf '%s\n' "$STREAM_SITE_URL"; return 0; }
  tmp="$(mktemp)"
  for src in "${STREAM_SOURCES[@]}"; do
    if curl -fsSL --connect-timeout 5 --max-time 15 --range 0-131071 "$src/" -o "$tmp" 2>/dev/null && grep -Eqi '<html|<!doctype|<head|<body' "$tmp"; then
      rm -f "$tmp"
      printf '%s\n' "$src"
      return 0
    fi
  done
  rm -f "$tmp"
  return 1
}

prepare_stream_source(){
  local chosen
  chosen="$(choose_stream_source)" || die "Все источники стрим-сайта недоступны: ${STREAM_SOURCES[*]}. Существующий сайт не трогаю."
  export STREAM_SITE_URL="$chosen"
  ok "Источник стрим-сайта: $STREAM_SITE_URL"
}

secret_env_len(){
  [ -f "$NODE_ENV" ] || { echo 0; return; }
  awk -F= '/^SECRET_KEY=/{print length(substr($0,index($0,"=")+1)); found=1; exit} END{if(!found) print 0}' "$NODE_ENV" 2>/dev/null
}

container_has_net_admin(){
  $SUDO docker inspect remnanode --format '{{json .HostConfig.CapAdd}}' 2>/dev/null | grep -q 'NET_ADMIN'
}

container_secret_matches(){
  local expected actual
  [ -f "$NODE_ENV" ] || return 1
  expected="$(awk -F= '/^SECRET_KEY=/{print substr($0,index($0,"=")+1); exit}' "$NODE_ENV" 2>/dev/null)"
  [ -n "$expected" ] || return 1
  actual="$($SUDO docker exec remnanode sh -c 'printf %s "$SECRET_KEY"' 2>/dev/null)" || return 1
  [ "$actual" = "$expected" ]
  unset expected actual
}

ensure_node_compose(){
  local compose="$NODE_COMPOSE" envfile="$NODE_ENV"
  local tmp tmpenv inline secret envlen need_recreate=0 backup_done=0 services service_count
  [ -f "$compose" ] || return 0

  services="$(cd "$NODE_DIR" && $SUDO docker compose config --services 2>/dev/null)" || { warn "Не удалось разобрать compose; изменения не применяю."; return 1; }
  service_count="$(printf '%s\n' "$services" | sed '/^[[:space:]]*$/d' | wc -l)"
  if [ "$service_count" -ne 1 ] || ! printf '%s\n' "$services" | grep -qx remnanode; then
    warn "Compose содержит дополнительные сервисы. Автоматическую AWK-миграцию отключаю, чтобы не изменить чужие SECRET_KEY/env_file/cap_add."
    return 1
  fi

  inline="$(awk '
    /^[[:space:]]*SECRET_KEY:[[:space:]]*/ {
      s=$0; sub(/^[[:space:]]*SECRET_KEY:[[:space:]]*/, "", s)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      if (substr(s,1,1)=="\"" && substr(s,length(s),1)=="\"") s=substr(s,2,length(s)-2)
      if (s != "${SECRET_KEY}" && s != "") print s
      exit
    }
  ' "$compose")"

  envlen="$(secret_env_len)"
  if [ -n "$inline" ]; then
    secret="$inline"
    tmpenv="$(mktemp)"
    [ -f "$envfile" ] && grep -v '^SECRET_KEY=' "$envfile" > "$tmpenv" || true
    printf 'SECRET_KEY=%s\n' "$secret" >> "$tmpenv"
    $SUDO install -o root -g root -m 0600 "$tmpenv" "$envfile"
    rm -f "$tmpenv"
    unset secret inline
    envlen="$(secret_env_len)"
    [ "$envlen" -gt 0 ] || die "SECRET_KEY не удалось безопасно перенести в $envfile."
    need_recreate=1
    ok "SECRET_KEY перенесён в $envfile (0600), значение не выводилось."
  fi

  if grep -qF '${SECRET_KEY}' "$compose" && [ "$envlen" -eq 0 ]; then
    warn "$envfile содержит пустой SECRET_KEY. Контейнер не пересоздаю, пока ключ не будет записан."
    return 1
  fi

  tmp="$(mktemp)"
  awk '
    /^[[:space:]]*SECRET_KEY:[[:space:]]*/ {next}
    {print}
  ' "$compose" > "$tmp"

  if grep -qE '^[[:space:]]*image:[[:space:]]*remnawave/node:latest[[:space:]]*$' "$tmp"; then
    sed -E "s#^([[:space:]]*image:[[:space:]]*)remnawave/node:latest[[:space:]]*$#\1${REMNA_NODE_IMAGE}#" "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
    need_recreate=1
    ok "Remnawave Node image зафиксирован: $REMNA_NODE_IMAGE"
  fi

  if ! grep -qE '^[[:space:]]*env_file:[[:space:]]*$' "$tmp"; then
    awk '
      {print}
      /^[[:space:]]*restart:[[:space:]]*/ && !done {
        match($0,/^[[:space:]]*/); i=substr($0,1,RLENGTH)
        print i "env_file:"
        print i "  - .env"
        done=1
      }
    ' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
    need_recreate=1
  fi

  if ! grep -qE '^[[:space:]]*-[[:space:]]*NET_ADMIN[[:space:]]*$' "$tmp"; then
    awk '
      {print}
      /^[[:space:]]*network_mode:[[:space:]]*host[[:space:]]*$/ && !done {
        match($0,/^[[:space:]]*/); i=substr($0,1,RLENGTH)
        print i "cap_add:"
        print i "  - NET_ADMIN"
        done=1
      }
    ' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
    need_recreate=1
  fi

  if ! cmp -s "$tmp" "$compose"; then
    $SUDO cp -a "$compose" "${compose}.bak.$(date +%Y%m%d-%H%M%S)"
    backup_done=1
    $SUDO install -o root -g root -m 0600 "$tmp" "$compose"
    need_recreate=1
  fi
  rm -f "$tmp"
  [ "$backup_done" = 1 ] && ok "docker-compose.yml обновлён безопасно; создан backup."

  envlen="$(secret_env_len)"
  [ "$envlen" -gt 0 ] || { warn "SECRET_KEY в $envfile отсутствует или пуст."; return 1; }
  $SUDO chmod 0600 "$envfile"

  ( cd "$NODE_DIR" && $SUDO docker compose config >/dev/null ) || die "docker-compose.yml не прошёл проверку."

  if $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
    container_has_net_admin || need_recreate=1
    container_secret_matches || need_recreate=1
  fi

  if [ "$need_recreate" = 1 ]; then
    ( cd "$NODE_DIR" && $SUDO docker compose up -d --force-recreate remnanode ) || die "Не удалось безопасно пересоздать remnanode."
    sleep 4
  fi

  container_has_net_admin || die "NET_ADMIN не применился к remnanode."
  container_secret_matches || die "SECRET_KEY внутри remnanode не совпадает с $NODE_ENV. Проверь env_file и пересоздание контейнера."
}

ensure_net_admin(){ ensure_node_compose; }

rw_core_on_443(){ ss -lntp 2>/dev/null | grep -E ':443[[:space:]]' | grep -q 'rw-core'; }
caddy_local_8443(){ ss -lntp 2>/dev/null | grep -E '127\.0\.0\.1:8443[[:space:]]' | grep -q 'caddy'; }
caddy_public_443(){ ss -lntp 2>/dev/null | grep -E ':443[[:space:]]' | grep -q 'caddy'; }
xhttp_on_7443(){ ss -lntp 2>/dev/null | grep -E '127\.0\.0\.1:7443[[:space:]]' | grep -q 'rw-core'; }

node_has_443_conflict(){
  command -v docker >/dev/null 2>&1 || return 1
  $SUDO docker logs --since 20s remnanode 2>&1 | tr -d '\000' | \
    grep -aEq 'failed to listen TCP on 443.*address already in use|listen tcp 0\.0\.0\.0:443: bind: address already in use|Xray Core process is not running anymore.*exitcode 255'
}

handoff_in_cooldown(){
  local until now
  [ -r "$HANDOFF_COOLDOWN" ] || return 1
  read -r until < "$HANDOFF_COOLDOWN" || return 1
  [[ "$until" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)"
  [ "$now" -lt "$until" ]
}

set_handoff_cooldown(){
  local until=$(( $(date +%s) + HANDOFF_COOLDOWN_SECONDS ))
  printf '%s\n' "$until" | $SUDO tee "$HANDOFF_COOLDOWN" >/dev/null
}

clear_handoff_cooldown(){ $SUDO rm -f "$HANDOFF_COOLDOWN" 2>/dev/null || true; }

switch_caddy_to_reality(){
  [ -s "$CADDY_REALITY" ] || return 1
  $SUDO caddy validate --config "$CADDY_REALITY" --adapter caddyfile >/dev/null || return 1
  [ -s "$CADDY_PUBLIC" ] || $SUDO cp -a "$CADDYFILE" "$CADDY_PUBLIC"
  $SUDO cp -a "$CADDYFILE" "${CADDYFILE}.before-reality.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  $SUDO install -o root -g root -m 0644 "$CADDY_REALITY" "$CADDYFILE"
  $SUDO systemctl restart caddy || return 1
  sleep 2
  caddy_local_8443
}

switch_caddy_to_public(){
  [ -s "$CADDY_PUBLIC" ] || return 1
  $SUDO caddy validate --config "$CADDY_PUBLIC" --adapter caddyfile >/dev/null || return 1
  $SUDO install -o root -g root -m 0644 "$CADDY_PUBLIC" "$CADDYFILE"
  $SUDO systemctl restart caddy || return 1
  sleep 2
  caddy_public_443
}

restore_public_caddy_if_needed(){
  rw_core_on_443 && return 0
  caddy_local_8443 || return 0
  switch_caddy_to_public || { warn "Не удалось вернуть Caddy на внешний :443."; return 1; }
  warn "REALITY/Xray не запущен — Caddy возвращён на :443, сайт сохранён."
}

auto_handoff_once(){
  local wait="${HANDOFF_WAIT_TIMEOUT:-35}" i
  [ -s "$CADDY_REALITY" ] || return 0

  if rw_core_on_443; then
    clear_handoff_cooldown
    if ! caddy_local_8443; then
      switch_caddy_to_reality || { warn "rw-core уже на :443, но Caddy не удалось перевести на 8443."; return 1; }
    fi
    return 0
  fi

  if caddy_public_443 && node_has_443_conflict; then
    if handoff_in_cooldown; then
      warn "Handoff недавно завершился rollback; повтор пропущен до окончания cooldown."
      return 0
    fi
    warn "Xray получил профиль, но :443 занят Caddy — выполняю автоматический handoff Caddy → 127.0.0.1:8443."
    switch_caddy_to_reality || { warn "Не удалось переключить Caddy на REALITY-конфиг."; return 1; }
    for ((i=1; i<=wait; i++)); do
      if rw_core_on_443; then
        clear_handoff_cooldown
        ok "REALITY поднялся автоматически: rw-core :443, Caddy 127.0.0.1:8443."
        return 0
      fi
      sleep 1
    done
    warn "После handoff rw-core не занял :443 за ${wait} сек — возвращаю публичный Caddy."
    switch_caddy_to_public || true
    set_handoff_cooldown
    warn "Повторный handoff заблокирован на ${HANDOFF_COOLDOWN_SECONDS} сек, чтобы исключить flap по старой записи лога."
    return 1
  fi
  return 0
}

install_handoff_watcher(){
  [ -s "$CADDY_REALITY" ] || return 0
  ensure_self || true
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
[Unit]
Description=Remna REALITY automatic Caddy handoff
After=docker.service caddy.service network-online.target

[Service]
Type=oneshot
ExecStart=$SELF handoff-check
EOF
  $SUDO install -o root -g root -m 0644 "$tmp" "$HANDOFF_SERVICE"
  cat > "$tmp" <<'EOF'
[Unit]
Description=Watch Remnanode for REALITY profile activation

[Timer]
OnBootSec=15s
OnUnitActiveSec=10s
AccuracySec=2s
Unit=remna-reality-handoff.service

[Install]
WantedBy=timers.target
EOF
  $SUDO install -o root -g root -m 0644 "$tmp" "$HANDOFF_TIMER"
  rm -f "$tmp"
  $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
  $SUDO systemctl enable --now remna-reality-handoff.timer >/dev/null 2>&1 || true
}

ensure_telemt_route_file(){
  local file="$1" tmp
  [ -f "$PANEL_CONFIG" ] || return 0
  [ -f "$file" ] || return 0
  grep -q 'handle /telemt\*' "$file" && return 0
  tmp="$(mktemp)"
  awk 'BEGIN{i=0} /^[[:space:]]*handle[[:space:]]*\{[[:space:]]*$/ && !i {print "\thandle /telemt* {"; print "\t\treverse_proxy 127.0.0.1:8080"; print "\t}"; print ""; i=1} {print}' "$file" > "$tmp"
  if $SUDO caddy validate --config "$tmp" --adapter caddyfile >/dev/null; then
    $SUDO install -o root -g root -m 0644 "$tmp" "$file"
  else
    warn "Не удалось безопасно восстановить /telemt в $file."
  fi
  rm -f "$tmp"
}

ensure_telemt_route(){
  ensure_telemt_route_file "$CADDYFILE"
  ensure_telemt_route_file "$CADDY_PUBLIC"
  ensure_telemt_route_file "$CADDY_REALITY"
  $SUDO systemctl reload caddy >/dev/null 2>&1 || $SUDO systemctl restart caddy >/dev/null 2>&1 || true
}

xray_status(){ $SUDO docker exec remnanode /command/s6-svstat /run/service/xray 2>/dev/null || true; }
runtime_config_count(){ $SUDO docker exec remnanode sh -c 'find /run /tmp /var/lib /opt -maxdepth 4 -type f \( -iname "*xray*.json" -o -name config.json \) 2>/dev/null | wc -l' 2>/dev/null || echo '?'; }

wait_for_xray_runtime(){
  local timeout="${XRAY_WAIT_TIMEOUT:-90}" i xs cfg
  $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode || return 1
  say "[*] Жду runtime-конфиг/Xray до ${timeout} секунд..."
  for ((i=1; i<=timeout; i++)); do
    auto_handoff_once >/dev/null 2>&1 || true
    xs="$(xray_status)"
    cfg="$(runtime_config_count)"
    if printf '%s' "$xs" | grep -q '^up' || xhttp_on_7443 || rw_core_on_443; then
      ok "Xray/runtime появился через ${i} сек."
      return 0
    fi
    if (( i % 15 == 0 )); then
      say "    ожидание: ${i}/${timeout} сек; Xray=${xs:-неизвестно}; runtime=${cfg:-?}"
    fi
    sleep 1
  done
  warn "За ${timeout} сек Xray не запустился и runtime-конфиг не появился."
  return 1
}

protection(){ ensure_protection_helper; "$PROTECTION_HELPER" "$@"; }

protection_node_api_readonly(){
  command -v iptables >/dev/null 2>&1 || return 1
  $SUDO iptables -C INPUT -j REMNA_GUARD >/dev/null 2>&1 || return 1
  $SUDO iptables -C REMNA_GUARD -p tcp --dport 2222 -j DROP >/dev/null 2>&1 || return 1
  $SUDO iptables -S REMNA_GUARD 2>/dev/null | grep -Eq -- '-p tcp .*--dport 2222 .* -j ACCEPT'
}

safe_diagnose(){
  set +e
  echo
  echo '────────────────────────────────────────────────────────────'
  echo '  Remna Node — безопасная диагностика'
  echo '────────────────────────────────────────────────────────────'

  # Diagnose is intentionally read-only: it must never rewrite compose/Caddy,
  # recreate containers, install watchers or perform a REALITY handoff.

  local xs cfgcount caps webcode=none xhttp=no nodeapi=no caddy_state domain secret_storage envlen conflict=no
  xs="$(xray_status 2>/dev/null)"
  cfgcount="$(runtime_config_count 2>/dev/null)"
  caps="$($SUDO docker inspect remnanode --format '{{json .HostConfig.CapAdd}}' 2>/dev/null || true)"
  ss -lntp 2>/dev/null | grep -q ':2222 ' && nodeapi=yes
  xhttp_on_7443 && xhttp=yes
  node_has_443_conflict && conflict=yes
  caddy_state="$($SUDO systemctl is-active caddy 2>/dev/null || true)"
  domain="$(awk '/^[A-Za-z0-9.-]+[[:space:]]*\{/{gsub(/[[:space:]]*\{.*/,"",$0); print $1; exit}' "$CADDYFILE" 2>/dev/null || true)"
  if caddy_public_443 && [ -n "$domain" ]; then
    webcode="$(curl -ksS --max-time 8 --resolve "${domain}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${domain}/" 2>/dev/null || true)"
  elif rw_core_on_443 && [ -n "$domain" ]; then
    webcode="$(curl -ksS --max-time 8 --resolve "${domain}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${domain}/" 2>/dev/null || true)"
  fi
  envlen="$(secret_env_len)"
  if [ "$envlen" -gt 0 ] && grep -qE '^[[:space:]]*env_file:' "$NODE_COMPOSE" 2>/dev/null; then secret_storage='✓ .env/env_file (0600)'; else secret_storage='✗ отсутствует/пуст'; fi

  echo
  echo '────────────────────────────────────────────────────────────'
  echo '  [A] Сервисы и порты'
  echo '────────────────────────────────────────────────────────────'
  printf '  Caddy       : %s\n' "${caddy_state:-неизвестно}"
  if [ "$webcode" = 200 ]; then printf '  Web :443    : ✓ HTTP 200\n'; else printf '  Web :443    : %s\n' "${webcode:-нет ответа}"; fi
  if [ "$nodeapi" = yes ]; then printf '  Node API    : ✓ :2222 слушает\n'; else printf '  Node API    : ✗ :2222 не слушает\n'; fi
  if [ "$xhttp" = yes ]; then printf '  XHTTP       : ✓ 127.0.0.1:7443 слушает\n'; else printf '  XHTTP       : ✗ 127.0.0.1:7443 не слушает\n'; fi
  if rw_core_on_443; then printf '  REALITY     : ✓ rw-core :443\n'; else printf '  REALITY     : не запущен\n'; fi
  if printf '%s' "$caps" | grep -q NET_ADMIN; then printf '  NET_ADMIN   : ✓ есть\n'; else printf '  NET_ADMIN   : ✗ нет\n'; fi
  printf '  SECRET_KEY  : %s\n' "$secret_storage"

  echo
  echo '────────────────────────────────────────────────────────────'
  echo '  [B] Remnanode / Xray'
  echo '────────────────────────────────────────────────────────────'
  printf '  Xray service: %s\n' "${xs:-неизвестно}"
  printf '  Runtime cfg : %s файл(ов)\n' "${cfgcount:-?}"
  if [ "$conflict" = yes ]; then
    echo '  ДИАГНОЗ     : профиль уже пришёл, но Xray упал из-за занятого :443.'
    echo '                Для исправления запусти selftest/repair: они могут безопасно выполнить handoff.'
  elif printf '%s' "$xs" | grep -q 'down (not started yet)' && [ "${cfgcount:-?}" = 0 ]; then
    echo '  ДИАГНОЗ     : Node API поднят, но runtime-конфиг Xray ещё не получен.'
    [ "$nodeapi" = yes ] && echo '                :2222 слушает — отсутствие 7443 само по себе НЕ означает локальный firewall.'
    echo '                Если панель пишет "Client network socket disconnected before secure TLS connection was established",'
    echo '                проверь версию панели: remnawave/backend:2 (2.8.x) несовместим с новым SNI Node 3.3.x; нужен backend 3.x.'
  elif printf '%s' "$xs" | grep -q '^down'; then
    echo '  ДИАГНОЗ     : Xray остановлен после попытки старта; смотри docker logs remnanode.'
  elif printf '%s' "$xs" | grep -q '^up'; then
    if [ "$xhttp" = yes ]; then echo '  ДИАГНОЗ     : Xray запущен, XHTTP backend доступен.'; else echo '  ДИАГНОЗ     : Xray запущен, но inbound 7443 отсутствует в назначенном профиле.'; fi
  else
    echo '  ДИАГНОЗ     : состояние Xray определить не удалось.'
  fi

  echo
  echo '────────────────────────────────────────────────────────────'
  echo '  [C] Caddy / сайт'
  echo '────────────────────────────────────────────────────────────'
  if caddy_local_8443 && rw_core_on_443; then
    echo '  ✓ Финальная схема: rw-core :443 → Caddy 127.0.0.1:8443.'
  elif caddy_public_443; then
    echo '  ✓ Публичный Caddy держит :443 до первого успешного старта REALITY.'
    [ -s "$CADDY_REALITY" ] && echo '  ✓ Авто-handoff armed: при ошибке Xray "address already in use" Caddy уйдёт на 8443 автоматически.'
  elif caddy_local_8443; then
    echo '  ! Caddy на 8443, но rw-core:443 пока отсутствует; watcher попробует завершить handoff или вернёт public.'
  else
    echo '  ✗ Не найден ожидаемый listener Caddy.'
  fi

  echo
  echo '────────────────────────────────────────────────────────────'
  echo '  [D] CDN'
  echo '────────────────────────────────────────────────────────────'
  if [ "$xhttp" = yes ]; then
    echo '  XHTTP backend поднят — теперь имеет смысл проверять CDN с внешнего клиента.'
  else
    echo '  CDN сейчас не первичная проблема: 127.0.0.1:7443 не слушает.'
  fi

  echo
  echo '────────────────────────────────────────────────────────────'
  echo '  [E] Защита / Node API'
  echo '────────────────────────────────────────────────────────────'
  if protection_node_api_readonly; then
    echo '  ✓ TCP/2222: REMNA_GUARD содержит allow + default DROP.'
  else
    echo '  ✗ TCP/2222 не защищён или защита не обнаружена. В меню выбери «Защита ноды» → «Задать IP панели».'
  fi
  set -e
  return 0
}

selftest_all(){
  local failed=0
  echo
  echo '════════════════════════════════════════════════════════════'
  echo ' Remna Node — SELFTEST + AUTO-REPAIR'
  echo '════════════════════════════════════════════════════════════'

  echo '[1/5] Remnanode compose / SECRET_KEY / NET_ADMIN'
  ensure_node_compose || failed=1

  echo '[2/5] Protection / 2222 / ipset / boot restore'
  protection selftest || failed=1

  echo '[3/5] REALITY handoff watcher'
  install_handoff_watcher || failed=1
  $SUDO systemctl enable --now remna-reality-handoff.timer >/dev/null 2>&1 || failed=1
  auto_handoff_once || true
  if $SUDO systemctl is-active remna-reality-handoff.timer >/dev/null 2>&1; then
    ok 'remna-reality-handoff.timer active'
  else
    warn 'remna-reality-handoff.timer не active'
    failed=1
  fi

  echo '[4/5] Caddy / Telemt routes'
  ensure_telemt_route || true
  if rw_core_on_443; then
    caddy_local_8443 && ok 'REALITY topology OK: rw-core:443 + Caddy:8443' || { warn 'rw-core на 443, но Caddy не на 8443'; failed=1; }
  elif caddy_public_443; then
    ok 'Caddy public:443 OK; watcher ждёт REALITY'
  else
    warn 'ни rw-core:443, ни Caddy:443 не обнаружены'
    failed=1
  fi

  echo '[5/5] Итоговая диагностика'
  safe_diagnose

  if [ "$failed" -eq 0 ]; then
    ok 'SELFTEST ALL: PASS'
    return 0
  fi
  warn 'SELFTEST ALL: есть неисправности, которые не удалось исправить автоматически.'
  return 1
}

run_core(){
  local cmd="${1:-menu}" wait_needed=0
  ensure_core
  case "$cmd" in install|--auto|auto|front-only|front|reinstall|stream|site|decoy|set-decoy) prepare_stream_source ;; esac
  bash "$CORE" "$@"
  case "$cmd" in
    install|--auto|auto|reinstall|repair|fix)
      ensure_node_compose
      if [ -n "${PANEL_IP:-}" ]; then PANEL_IP_ENV="$PANEL_IP" protection ensure-panel || warn "Не удалось ограничить TCP/2222 IP панели.";
      else protection ensure-panel || warn "TCP/2222 пока не ограничен: задай IP панели в разделе защиты."; fi
      wait_needed=1
      ;;
  esac
  case "$cmd" in install|--auto|auto|reinstall|repair|fix|reality-prepare|reality-enable)
      install_handoff_watcher || true
      ;;
  esac
  if [ "$wait_needed" = 1 ]; then
    if ! wait_for_xray_runtime; then
      restore_public_caddy_if_needed || true
      warn "Node bootstrap завершён, но Xray runtime пока не применён. Публичный сайт сохранён; watcher ждёт профиль и сам отдаст :443 REALITY."
    fi
  else
    auto_handoff_once || true
  fi
  ensure_telemt_route || true
}

telemt(){ ensure_telemt_helper; "$TELEMT_HELPER" "$@"; }

menu(){
  while true; do
    cat <<'MENU'

────────────────────────────────────────────────────────────
Remna Node Manager — safe mode
────────────────────────────────────────────────────────────
 [1]  Полная установка
 [2]  Переустановка с нуля
 [3]  Только фронт Caddy
 [4]  Сгенерировать XHTTP-путь
 [5]  Изменить XHTTP-путь
 [6]  Обновить стрим-сайт
 [7]  Сводка настроек
 [8]  Диагностика
 [9]  Статус сервисов
 [10] Подготовить REALITY
 [11] Включить REALITY
 [12] Отключить REALITY
 [13] Файлы REALITY
 [14] Repair текущей ноды
 [15] Безопасно подключить Telemt + Panel
 [16] Статус Telemt + Panel
 [17] Убрать интеграцию Telemt Panel
 [18] Clean Remnanode/Caddy
 [19] Защита ноды (RKN/TSPU/GOV/GeoIP/Allow/Deny)
 [20] Закрыть TCP/2222 только для IP панели
 [21] SELFTEST + авторемонт всего узла
 [0]  Выход
────────────────────────────────────────────────────────────
MENU
    printf 'Выбор: '; local c p; read -r c <"$TTY" || true
    case "$c" in
      1) run_core install ;; 2) run_core reinstall ;; 3) run_core front-only ;; 4) run_core path ;;
      5) printf 'Новый XHTTP-путь: '; read -r p <"$TTY" || true; [ -n "$p" ] && run_core path-set "$p" ;;
      6) run_core stream ;; 7) run_core summary ;; 8) safe_diagnose ;; 9) run_core status ;;
      10) run_core reality-prepare ;; 11) run_core reality-enable ;; 12) run_core reality-disable ;; 13) run_core reality-info ;;
      14) run_core repair ;; 15) telemt install ;; 16) telemt status ;; 17) telemt remove ;; 18) run_core clean ;;
      19) protection menu ;; 20) protection panel-set ;; 21) selftest_all ;;
      0|'') exit 0 ;; *) warn "Неизвестный пункт: $c" ;;
    esac
    printf '\nEnter — вернуться в меню... '; read -r _ <"$TTY" || true
  done
}

main(){
  ensure_self || true
  case "${1:-menu}" in
    menu|'') menu ;;
    diagnose|diag) safe_diagnose ;;
    selftest|self-test|check-all|repair-all) selftest_all ;;
    handoff-check) set +e; auto_handoff_once; exit 0 ;;
    telemt-install) telemt install ;; telemt-status) telemt status ;; telemt-remove|telemt-uninstall) telemt remove ;;
    protect|protection) protection menu ;; protect-install) protection install ;; protect-status) protection status ;; protect-selftest) protection selftest ;;
    panel-set) shift; protection panel-set "${1:-}" ;;
    *) run_core "$@" ;;
  esac
}
main "$@"
