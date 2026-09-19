#!/usr/bin/env bash
set -Eeo pipefail

REPO_REF=1f46e9b186c5fd57afe2a25e9cc2b4ef19bff4d6
REPO_RAW="https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/${REPO_REF}"
CORE_BLOB_SHA=7c283708c212fda60d9c4e628229192cb14f1874
PROTECTION_BLOB_SHA=550d5e1d6342005355657d129c5c99122fa769d7
CADDY_GUARD_BLOB_SHA=e5a6c6f03682bbe0551184dfdb35c3f22ca1c62e
REMNA_NODE_IMAGE="${REMNA_NODE_IMAGE:-remnawave/node:3.4.1}"
INSTALL_DIR=/opt/remna-node-scripts
SELF="$INSTALL_DIR/install-caddy-node-reality-stream.sh"
CORE="$INSTALL_DIR/install-caddy-node-reality-stream-core.sh"
PROTECTION_HELPER="$INSTALL_DIR/protection-manager.sh"
CADDY_GUARD="$INSTALL_DIR/caddy-resilient-start.sh"
NODE_DIR=/opt/remnanode
NODE_COMPOSE="$NODE_DIR/docker-compose.yml"
NODE_ENV="$NODE_DIR/.env"
REALITY_SOCKET_DIR=/dev/shm/remna-reality
REALITY_SOCKET_HOST=$REALITY_SOCKET_DIR/nginx.sock
REALITY_SOCKET_TARGET=/dev/shm/nginx.sock
CADDYFILE=/etc/caddy/Caddyfile
CADDY_PUBLIC=/etc/caddy/Caddyfile.public
CADDY_REALITY=/etc/caddy/Caddyfile.reality
HANDOFF_SERVICE=/etc/systemd/system/remna-reality-handoff.service
HANDOFF_TIMER=/etc/systemd/system/remna-reality-handoff.timer
HANDOFF_COOLDOWN=/run/remna-reality-handoff.cooldown
HANDOFF_COOLDOWN_SECONDS=${HANDOFF_COOLDOWN_SECONDS:-300}
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
TTY=/dev/tty; { [ -r "$TTY" ] && [ -w "$TTY" ]; } || TTY=/dev/stdin
say(){ printf '%s\n' "$*"; }
ok(){ printf '✓ %s\n' "$*"; }
warn(){ printf '! %s\n' "$*" >&2; }
die(){ printf '✗ %s\n' "$*" >&2; exit 1; }
MENU_BACK_RC=20
IN_MANAGER_MENU=0
is_menu_back(){ case "${1:-}" in 0|q|Q|back|BACK|Back|назад|Назад|НАЗАД) return 0 ;; *) return 1 ;; esac; }
back_to_manager_menu(){
  if [ "$IN_MANAGER_MENU" -eq 1 ]; then
    return 0
  fi
  menu
}
menu_action(){
  local rc=0
  "$@" || rc=$?
  if [ "$rc" -eq "$MENU_BACK_RC" ]; then
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    warn "Операция завершилась с кодом $rc — возвращаюсь в меню."
  fi
  return 0
}

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

ensure_protection_helper(){
  if download_checked "$REPO_RAW/protection-manager.sh" "$PROTECTION_BLOB_SHA" "$PROTECTION_HELPER"; then return 0; fi
  verified_script "$PROTECTION_HELPER" "$PROTECTION_BLOB_SHA" && { warn "GitHub недоступен — использую локальный protection helper с ожидаемым blob SHA."; return 0; }
  die "Не удалось получить protection-manager.sh."
}

ensure_caddy_guard_helper(){
  if download_checked "$REPO_RAW/caddy-resilient-start.sh" "$CADDY_GUARD_BLOB_SHA" "$CADDY_GUARD"; then return 0; fi
  verified_script "$CADDY_GUARD" "$CADDY_GUARD_BLOB_SHA" && { warn "GitHub недоступен — использую локальный Caddy guard с ожидаемым blob SHA."; return 0; }
  die "Не удалось получить caddy-resilient-start.sh."
}

arm_caddy_guard(){
  command -v systemctl >/dev/null 2>&1 || return 0
  ensure_caddy_guard_helper
  CADDYFILE="$CADDYFILE" CADDY_PUBLIC="$CADDY_PUBLIC" CADDY_REALITY="$CADDY_REALITY" \
    $SUDO "$CADDY_GUARD" install-dropin
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

container_has_reality_socket_mount(){
  $SUDO docker inspect remnanode --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' 2>/dev/null |
    grep -Fq "$REALITY_SOCKET_DIR -> /dev/shm"
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

  if ! grep -Fq "$REALITY_SOCKET_DIR:/dev/shm" "$tmp"; then
    $SUDO install -d -o root -g root -m 0755 "$REALITY_SOCKET_DIR"
    if grep -qE '^    volumes:[[:space:]]*$' "$tmp"; then
      awk -v mount="      - $REALITY_SOCKET_DIR:/dev/shm" '
        {print}
        /^    volumes:[[:space:]]*$/ && !done {print mount; done=1}
      ' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
    else
      awk -v mount="$REALITY_SOCKET_DIR:/dev/shm" '
        {print}
        /^    network_mode:[[:space:]]*host[[:space:]]*$/ && !done {
          print "    volumes:"
          print "      - " mount
          done=1
        }
      ' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
    fi
    need_recreate=1
    ok "Добавлен shared /dev/shm mount для REALITY self-steal socket."
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
    container_has_reality_socket_mount || need_recreate=1
  fi

  if [ "$need_recreate" = 1 ]; then
    ( cd "$NODE_DIR" && $SUDO docker compose up -d --force-recreate remnanode ) || die "Не удалось безопасно пересоздать remnanode."
    sleep 4
  fi

  container_has_net_admin || die "NET_ADMIN не применился к remnanode."
  container_secret_matches || die "SECRET_KEY внутри remnanode не совпадает с $NODE_ENV. Проверь env_file и пересоздание контейнера."
  container_has_reality_socket_mount || die "Shared /dev/shm mount для REALITY self-steal не применился к remnanode."
}

ensure_net_admin(){ ensure_node_compose; }

rw_core_on_443(){ ss -lntp 2>/dev/null | grep -E ':443[[:space:]]' | grep -q 'rw-core'; }
caddy_local_8443(){ ss -lntp 2>/dev/null | grep -E '127\.0\.0\.1:8443[[:space:]]' | grep -q 'caddy'; }
caddy_public_443(){ ss -lntp 2>/dev/null | grep -E ':443[[:space:]]' | grep -q 'caddy'; }

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

caddy_prepare_for_owner(){
  ensure_caddy_guard_helper
  CADDYFILE="$CADDYFILE" CADDY_PUBLIC="$CADDY_PUBLIC" CADDY_REALITY="$CADDY_REALITY" \
    $SUDO "$CADDY_GUARD" prepare
}

restart_caddy_for_owner(){
  caddy_prepare_for_owner || return 1
  $SUDO systemctl restart caddy || return 1
  sleep 2
  if rw_core_on_443; then caddy_local_8443; else caddy_public_443; fi
}

wait_for_rw_core_443(){
  local wait="${1:-35}" i
  for ((i=1; i<=wait; i++)); do
    rw_core_on_443 && return 0
    sleep 1
  done
  return 1
}

restart_remnanode_if_present(){
  command -v docker >/dev/null 2>&1 || return 0
  $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx remnanode || return 0
  $SUDO docker restart remnanode >/dev/null 2>&1 || true
}

handoff_caddy_to_rw_core(){
  local wait="${HANDOFF_WAIT_TIMEOUT:-35}"
  [ -s "$CADDY_REALITY" ] || return 0
  caddy_prepare_for_owner >/dev/null 2>&1 || return 1
  warn "Xray получил REALITY, но :443 занят Caddy — освобождаю :443 и жду rw-core."
  $SUDO systemctl stop caddy || return 1
  sleep 1
  restart_remnanode_if_present
  if wait_for_rw_core_443 "$wait"; then
    restart_caddy_for_owner || return 1
    ok "REALITY поднялся автоматически: rw-core :443, Caddy 127.0.0.1:8443."
    return 0
  fi
  warn "rw-core не занял :443 за ${wait} сек — возвращаю публичный Caddy."
  restart_caddy_for_owner || true
  set_handoff_cooldown
  warn "Повторный handoff заблокирован на ${HANDOFF_COOLDOWN_SECONDS} сек, чтобы исключить flap по старой записи лога."
  return 1
}

restore_public_caddy_if_needed(){
  rw_core_on_443 && return 0
  caddy_local_8443 || return 0
  restart_caddy_for_owner || { warn "Не удалось вернуть Caddy на внешний :443."; return 1; }
  warn "REALITY/Xray не запущен — Caddy возвращён на :443, сайт сохранён."
}

auto_handoff_once(){
  [ -s "$CADDY_REALITY" ] || return 0

  if rw_core_on_443; then
    clear_handoff_cooldown
    if ! caddy_local_8443; then
      restart_caddy_for_owner || { warn "rw-core уже на :443, но Caddy не удалось перевести на 8443."; return 1; }
    fi
    return 0
  fi

  if caddy_public_443 && node_has_443_conflict; then
    if handoff_in_cooldown; then
      warn "Handoff недавно завершился rollback; повтор пропущен до окончания cooldown."
      return 0
    fi
    handoff_caddy_to_rw_core || return 1
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

xray_status(){ $SUDO docker exec remnanode /command/s6-svstat /run/service/xray 2>/dev/null || true; }
runtime_config_count(){ $SUDO docker exec remnanode sh -c 'find /run /tmp /var/lib /opt -maxdepth 4 -type f \( -iname "*xray*.json" -o -name config.json \) 2>/dev/null | wc -l' 2>/dev/null || echo '?'; }

wait_for_xray_runtime(){
  local timeout="${XRAY_WAIT_TIMEOUT:-90}" i xs cfg
  $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode || return 1
  say "[*] Жду единый XHTTP+REALITY runtime на :443 до ${timeout} секунд..."
  for ((i=1; i<=timeout; i++)); do
    auto_handoff_once >/dev/null 2>&1 || true
    xs="$(xray_status)"
    cfg="$(runtime_config_count)"
    if rw_core_on_443; then
      ok "XHTTP+REALITY :443 появился через ${i} сек."
      return 0
    fi
    if (( i % 15 == 0 )); then
      say "    ожидание: ${i}/${timeout} сек; Xray=${xs:-неизвестно}; runtime=${cfg:-?}; :443=не rw-core"
    fi
    sleep 1
  done
  warn "За ${timeout} сек rw-core не занял :443. Проверь единый XHTTP+REALITY Config Profile."
  return 1
}
protection(){
  ensure_protection_helper
  local rc=0
  "$PROTECTION_HELPER" "$@" || rc=$?
  return "$rc"
}

protection_node_api_readonly(){
  command -v iptables >/dev/null 2>&1 || return 1
  $SUDO iptables -C INPUT -j REMNA_GUARD >/dev/null 2>&1 || return 1
  $SUDO iptables -C REMNA_GUARD -p tcp --dport 2222 -j DROP >/dev/null 2>&1 || return 1
  $SUDO iptables -S REMNA_GUARD 2>/dev/null | awk '
    /-A REMNA_GUARD/ && /-p tcp/ && /--dport 2222/ && /-j ACCEPT/ {allow=1}
    END {exit allow ? 0 : 1}
  '
}

safe_diagnose(){
  set +e
  echo
  echo '────────────────────────────────────────────────────────────'
  echo '  Remna Node — безопасная диагностика'
  echo '────────────────────────────────────────────────────────────'
  local failed=0 xs cfgcount caddy_state nodeapi=no socket_host=no socket_node=no
  xs="$(xray_status 2>/dev/null)"
  cfgcount="$(runtime_config_count 2>/dev/null)"
  caddy_state="$($SUDO systemctl is-active caddy 2>/dev/null || true)"
  ss -lntp 2>/dev/null | grep -q ':2222 ' && nodeapi=yes
  [ -S "$REALITY_SOCKET_DIR/nginx.sock" ] && socket_host=yes
  $SUDO docker exec remnanode test -S "$REALITY_SOCKET_TARGET" >/dev/null 2>&1 && socket_node=yes
  printf '  Caddy       : %s\n' "${caddy_state:-неизвестно}"
  printf '  Xray        : %s\n' "${xs:-неизвестно}"
  printf '  Runtime cfg : %s файл(ов)\n' "${cfgcount:-?}"
  printf '  Node API    : %s\n' "$([ "$nodeapi" = yes ] && echo "✓ :2222" || echo "✗ :2222")"
  printf '  Host socket : %s\n' "$socket_host"
  printf '  Node socket : %s\n' "$socket_node"
  if rw_core_on_443; then
    echo '  XHTTP+REALITY: ✓ rw-core 0.0.0.0:443'
    caddy_local_8443 || { warn "Caddy fallback 127.0.0.1:8443 отсутствует."; failed=1; }
    [ "$socket_host" = yes ] || { warn "Host self-steal socket отсутствует."; failed=1; }
    [ "$socket_node" = yes ] || { warn "remnanode не видит /dev/shm/nginx.sock."; failed=1; }
  elif caddy_public_443; then
    echo '  XHTTP+REALITY: профиль ещё не активен; Caddy держит :443'
  else
    warn "Ни rw-core, ни Caddy не держат :443."; failed=1
  fi
  protection_node_api_readonly || { warn "TCP/2222 не защищён правилом REMNA_GUARD."; failed=1; }
  set -e
  [ "$failed" -eq 0 ]
}
selftest_all(){
  local failed=0
  echo
  echo '════════════════════════════════════════════════════════════'
  echo ' Remna Node — FULL INFRASTRUCTURE SELF-TEST'
  echo '════════════════════════════════════════════════════════════'

  echo '[1/5] Remnanode compose / SECRET_KEY / NET_ADMIN'
  ensure_node_compose || failed=1

  echo '[2/5] Protection / 2222 / ipset / boot restore'
  protection selftest || failed=1

  echo '[3/5] Caddy topology guard / REALITY handoff watcher'
  arm_caddy_guard || failed=1
  install_handoff_watcher || failed=1
  $SUDO systemctl enable --now remna-reality-handoff.timer >/dev/null 2>&1 || failed=1
  auto_handoff_once || true
  if $SUDO systemctl is-active remna-reality-handoff.timer >/dev/null 2>&1; then
    ok 'remna-reality-handoff.timer active'
  else
    warn 'remna-reality-handoff.timer не active'
    failed=1
  fi

  echo '[4/5] Caddy topology'
  if rw_core_on_443; then
    caddy_local_8443 && ok 'REALITY topology OK: rw-core:443 + Caddy:8443' || { warn 'rw-core на 443, но Caddy не на 8443'; failed=1; }
  elif caddy_public_443; then
    ok 'Caddy public:443 OK; watcher ждёт REALITY'
  else
    warn 'ни rw-core:443, ни Caddy:443 не обнаружены'
    failed=1
  fi

  if rw_core_on_443; then
    [ -S "$REALITY_SOCKET_DIR/nginx.sock" ] || { warn 'Host self-steal socket отсутствует.'; failed=1; }
    $SUDO docker exec remnanode test -S "$REALITY_SOCKET_TARGET" >/dev/null 2>&1 || { warn 'remnanode не видит /dev/shm/nginx.sock.'; failed=1; }
  fi
  protection_node_api_readonly || { warn 'Финальная проверка защиты TCP/2222 не пройдена.'; failed=1; }

  echo '[5/5] Итоговая диагностика'
  safe_diagnose

  if [ "$failed" -eq 0 ]; then
    ok 'FULL INFRASTRUCTURE SELF-TEST: PASS'
    return 0
  fi
  warn 'FULL INFRASTRUCTURE SELF-TEST: есть неисправности, которые не удалось исправить автоматически.'
  return 1
}

run_core(){
  local cmd="${1:-menu}" wait_needed=0
  ensure_core
  case "$cmd" in install|--auto|auto|front-only|front|reinstall|repair|fix|reality-prepare|reality-enable|reality-disable|path-set|set-path)
      arm_caddy_guard
      ;;
  esac
  # Core uses a built-in static decoy by default. External site content is
  # accepted only when the operator explicitly supplies a pinned SHA-256.
  local core_rc=0 protection_rc=0
  bash "$CORE" "$@" || core_rc=$?
  if [ "$core_rc" -eq "$MENU_BACK_RC" ]; then
    back_to_manager_menu
    return 0
  fi
  [ "$core_rc" -eq 0 ] || return "$core_rc"
  case "$cmd" in
    install|--auto|auto|reinstall|repair|fix)
      ensure_node_compose
      if [ -n "${PANEL_IP:-}" ]; then
        PANEL_IP_ENV="$PANEL_IP" protection ensure-panel || protection_rc=$?
      else
        protection ensure-panel || protection_rc=$?
      fi
      if [ "$protection_rc" -eq "$MENU_BACK_RC" ]; then
        warn "Настройка TCP/2222 отложена — возвращаюсь в меню."
        back_to_manager_menu
        return 0
      elif [ "$protection_rc" -ne 0 ]; then
        warn "TCP/2222 пока не ограничен: задай IP панели в разделе защиты."
      fi
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
      warn "Node bootstrap завершён, но XHTTP+REALITY runtime :443 пока не применён. Проверь назначенный Config Profile."
    fi
  else
    auto_handoff_once || true
  fi
}

menu(){
  IN_MANAGER_MENU=1
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
 [13] Профиль для копипасты (XHTTP + REALITY :443)
 [14] Repair Caddy / XHTTP / REALITY
 [15] Clean Remnanode/Caddy
 [16] Защита ноды (RKN/TSPU/GOV/GeoIP/Allow/Deny)
 [17] Закрыть TCP/2222 только для IP панели
 [18] Полный self-test инфраструктуры
 [19] РКН защита (TSPU/GOV)
 [0]  Выход
────────────────────────────────────────────────────────────
MENU
    printf 'Выбор: '; local c p; read -r c <"$TTY" || true
    case "$c" in
      1) menu_action run_core install ;;
      2) menu_action run_core reinstall ;;
      3) menu_action run_core front-only ;;
      4) menu_action run_core path ;;
      5)
        printf 'Новый XHTTP-путь (0 = назад): '; read -r p <"$TTY" || true
        is_menu_back "$p" || { [ -n "$p" ] && menu_action run_core path-set "$p"; }
        ;;
      6) menu_action run_core stream ;;
      7) menu_action run_core summary ;;
      8) menu_action safe_diagnose ;;
      9) menu_action run_core status ;;
      10) menu_action run_core reality-prepare ;;
      11) menu_action run_core reality-enable ;;
      12) menu_action run_core reality-disable ;;
      13) menu_action run_core config-profile ;;
      14) menu_action run_core repair ;;
      15)
        printf 'Снести локальный Remnanode/Caddy? Введите YES (0 = назад): '
        read -r p <"$TTY" || true
        if is_menu_back "$p"; then
          :
        elif [ "$p" = YES ]; then
          menu_action run_core clean
        else
          warn "Clean отменён."
        fi
        ;;
      16) menu_action protection menu ;;
      17) menu_action protection panel-set ;;
      18) menu_action selftest_all ;;
      19) menu_action protection rkn ;;
      0|'') exit 0 ;;
      *) warn "Неизвестный пункт: $c" ;;
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
    protect|protection) protection menu ;; rkn|rkn-protection) protection rkn ;; protect-install) protection install ;; protect-status) protection status ;; protect-selftest) protection selftest ;;
    panel-set)
      shift
      rc=0
      protection panel-set "${1:-}" || rc=$?
      if [ "$rc" -eq "$MENU_BACK_RC" ]; then back_to_manager_menu; elif [ "$rc" -ne 0 ]; then return "$rc"; fi
      ;;
    *) run_core "$@" ;;
  esac
}
main "$@"
