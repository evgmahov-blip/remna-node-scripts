#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

TASK_NAME="REMNA NODE NEXT"
REPO="evgmahov-blip/remna-node-scripts"
SOURCE_REF="d0113fb15d1c332e12b13ce547d31d7711dec337"
SOURCE_BLOB_SHA="43f83602f43f450c0c7e6df15f97b908e39037c8"
SOURCE_URL="https://raw.githubusercontent.com/${REPO}/${SOURCE_REF}/vendor/remna-next-source.tar.gz"

APP_DIR="/opt/remnanode"
NEXT_DIR="$APP_DIR/next-installer"
CLI="/usr/local/bin/remnanode-next"
SELF="/usr/local/libexec/remnanode-next.sh"
LEGACY="$NEXT_DIR/setup_node-legacy.sh"
TRANSPORT="$NEXT_DIR/remnawave-transport-manager.sh"
SELFSTEAL="$NEXT_DIR/selfsteal-site-manager.sh"
RKN="$NEXT_DIR/rkn-watcher-manager.sh"
GUARDS="$NEXT_DIR/next-runtime-guards.sh"
SIGNATURE="$NEXT_DIR/xhttp-signature-manager.sh"
TTY=/dev/tty
[[ -r "$TTY" ]] || TTY=/dev/stdin

EXPECTED_SETUP="728ed22841a1c494a9d9fce026109f6151fe16a2b861496d267005bd4850477c"
EXPECTED_GUARDS="620797d0677d091d6550894e32fea58ce7f2adf2f125d6f6ccfb217a7b3382fd"
EXPECTED_TRANSPORT="441c82fb0eb3b155986d7b84bd66aa82bb1d028b8a9c49e02f1fbac326fac2e2"
EXPECTED_RKN="2d5838809881a00cac755b43606d7c929e7ba8f5786f64ebff849eb73edeb3e7"
EXPECTED_SELFSTEAL="b783e94f2ef3764b2e397cba9eb96aeab88d7da11da017a2c867054f9546a84a"
EXPECTED_SIGNATURE="dbbd1110aec2e6dd32aee204b6d0174d7fe511e1b97118570cbbea553946bd4a"

say(){ printf '%s\n' "$*"; }
ok(){ printf '[OK] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
pause(){ printf 'Enter — продолжить... '; read -r _ < "$TTY" || true; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Запусти от root.'; }
apt_get(){ DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 "$@"; }

git_blob_sha(){
  local file="$1" size
  size="$(wc -c <"$file" | tr -d '[:space:]')"
  { printf 'blob %s\000' "$size"; cat "$file"; } | sha1sum | awk '{print $1}'
}

ensure_bootstrap_deps(){
  local missing=0
  for c in curl tar sha256sum sed awk diff python3; do command -v "$c" >/dev/null 2>&1 || missing=1; done
  if (( missing )); then
    command -v apt-get >/dev/null 2>&1 || die 'Не хватает bootstrap-зависимостей и apt-get недоступен.'
    apt_get update -y
    apt_get install -y curl ca-certificates tar gzip coreutils diffutils python3
  fi
}

verify_source_file(){
  local file="$1" expected="$2" got
  [[ -s "$file" ]] || die "В NEXT bundle отсутствует $(basename "$file")"
  got="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$got" == "$expected" ]] || die "SHA256 mismatch: $(basename "$file"): $got != $expected"
  bash -n "$file" || die "bash -n failed: $(basename "$file")"
}

patch_hysteria_compat(){
  local file="$1"
  python3 - "$file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding='utf-8')

replacements = [
    (
        'HYSTERIA_CERT_MOUNT_ACTION="${HYSTERIA_CERT_MOUNT_ACTION:-}"',
        'HYSTERIA_CERT_MOUNT_ACTION="${HYSTERIA_CERT_MOUNT_ACTION:-}"\nHYSTERIA_CONGESTION="${HYSTERIA_CONGESTION:-brutal}"',
        'HYSTERIA_CONGESTION'
    ),
    (
        '"settings": {"version": 2, "users": []},',
        '"settings": {"version": 2, "clients": []},',
        'Remnawave clients array'
    ),
    (
        '''        "network": "hysteria",
        "security": "tls",
        "hysteriaSettings": {''',
        '''        "network": "hysteria",
        "security": "tls",
        "finalmask": {
          "quicParams": {
            "debug": false,
            "congestion": "$HYSTERIA_CONGESTION"
          }
        },
        "hysteriaSettings": {''',
        'Hysteria finalmask'
    ),
    (
        '''ALPN: h3
Masquerade: встроенная копия текущего SelfSteal index.html''',
        '''ALPN: h3
Auth: автоматически = UUID пользователя Remnawave (backend добавляет settings.clients[].auth)
Final Mask / streamOverrides.finalMask: {"quicParams":{"congestion":"$HYSTERIA_CONGESTION"}}
Masquerade: встроенная копия текущего SelfSteal index.html''',
        'Hysteria Host finalMask hint'
    ),
]

for old, new, label in replacements:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'[ERROR] hysteria compat patch: {label}: expected 1 match, got {count}')
    text = text.replace(old, new, 1)

path.write_text(text, encoding='utf-8')
PY

  bash -n "$file" || die 'Hysteria compatibility patch сломал syntax transport-manager.'
  grep -Fq '"settings": {"version": 2, "clients": []}' "$file" || die 'Hysteria patch: clients[] не применён.'
  grep -Fq '"congestion": "$HYSTERIA_CONGESTION"' "$file" || die 'Hysteria patch: finalmask не применён.'
  grep -Fq 'streamOverrides.finalMask' "$file" || die 'Hysteria patch: Host finalMask hint отсутствует.'
  ok 'Hysteria2 profile приведён к рабочему Remnawave/Xray формату: clients[] + finalmask brutal.'
}

sync_next_sources(){
  ensure_bootstrap_deps
  local tmp bundle listing
  tmp="$(mktemp -d)"
  bundle="$tmp/source.tar.gz"

  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 90 --retry 3 \
    "$SOURCE_URL" -o "$bundle" || die 'Не удалось скачать закреплённый NEXT source bundle.'
  [[ "$(git_blob_sha "$bundle")" == "$SOURCE_BLOB_SHA" ]] || die 'NEXT source bundle не прошёл Git blob SHA.'

  listing="$tmp/listing.txt"
  tar -tzf "$bundle" | sed '/\/$/d' | LC_ALL=C sort > "$listing"
  cat > "$tmp/expected.txt" <<'FILES'
next-installer/next-runtime-guards.sh
next-installer/remnawave-transport-manager.sh
next-installer/rkn-watcher-manager.sh
next-installer/selfsteal-site-manager.sh
next-installer/setup_node-legacy.sh
next-installer/xhttp-signature-manager.sh
FILES
  if ! diff -u "$tmp/expected.txt" "$listing"; then
    die 'Состав NEXT source bundle отличается от ожидаемого.'
  fi

  tar -xzf "$bundle" -C "$tmp"
  verify_source_file "$tmp/next-installer/setup_node-legacy.sh" "$EXPECTED_SETUP"
  verify_source_file "$tmp/next-installer/next-runtime-guards.sh" "$EXPECTED_GUARDS"
  verify_source_file "$tmp/next-installer/remnawave-transport-manager.sh" "$EXPECTED_TRANSPORT"
  patch_hysteria_compat "$tmp/next-installer/remnawave-transport-manager.sh"
  verify_source_file "$tmp/next-installer/rkn-watcher-manager.sh" "$EXPECTED_RKN"
  verify_source_file "$tmp/next-installer/selfsteal-site-manager.sh" "$EXPECTED_SELFSTEAL"
  verify_source_file "$tmp/next-installer/xhttp-signature-manager.sh" "$EXPECTED_SIGNATURE"

  install -d -m 0700 "$NEXT_DIR" /usr/local/libexec
  install -m 0700 "$tmp/next-installer/"*.sh "$NEXT_DIR/"

  if [[ -f "$0" ]]; then
    local current
    current="$(readlink -f "$0")"
    if [[ "$current" != "$SELF" ]]; then
      install -m 0700 "$current" "$SELF"
    fi
    ln -sfn "$SELF" "$CLI"
  fi
  ok "NEXT source синхронизирован → $NEXT_DIR"
  rm -rf "$tmp"
}

legacy_call(){
  local fn="$1"
  [[ -x "$LEGACY" ]] || die "Не найден $LEGACY"
  bash -Eeuo pipefail -c '
    legacy="$1"; fn="$2"
    source <(sed -e "\$d" "$legacy")
    check_os
    detect_arch
    "$fn"
  ' "$LEGACY" "$LEGACY" "$fn"
}

base_install(){
  sync_next_sources
  if [[ -s "$APP_DIR/docker-compose.yml" ]] && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
    warn 'Базовая Remnanode уже существует — первоначальную установку не повторяю.'
    return 0
  fi
  legacy_call run_initial_setup
}

post_transport(){
  local transport=""
  [[ -r "$APP_DIR/.transport" ]] && transport="$(tr -d '[:space:]' < "$APP_DIR/.transport")"
  case "$transport" in
    xhttp|combined)
      "$SIGNATURE" apply || warn 'XHTTP signature не применена; профиль оставлен в предыдущем рабочем состоянии.'
      ;;
  esac
  case "$transport" in
    hysteria|combined)
      "$GUARDS" restore-hysteria || warn 'Проверь cert mount Hysteria2.'
      ;;
  esac
}

transport_menu(){
  sync_next_sources
  [[ -s "$APP_DIR/docker-compose.yml" ]] || die 'Сначала установи базовую ноду.'
  "$TRANSPORT"
  post_transport
}

copy_profile_menu(){
  sync_next_sources
  local choice file=""
  while true; do
    cat <<'MENU'

────────────────────────────────────────────────────────────
Config Profile — копипаста в Remnawave
────────────────────────────────────────────────────────────
 [1] XHTTP + REALITY         (TCP/443)
 [2] RAW + REALITY           (TCP/443)
 [3] Hysteria2 + TLS         (UDP/443)
 [4] XHTTP + Hysteria2       (TCP/443 + UDP/443)
 [0] Назад
────────────────────────────────────────────────────────────
MENU
    printf 'Выбор: '; read -r choice < "$TTY" || true
    case "$choice" in
      1) file="$APP_DIR/remnawave-profiles/xhttp-reality.json" ;;
      2) file="$APP_DIR/remnawave-profiles/raw-reality.json" ;;
      3) file="$APP_DIR/remnawave-profiles/hysteria2-tls.json" ;;
      4) file="$APP_DIR/remnawave-profiles/xhttp-hysteria2.json" ;;
      0|'') return 0 ;;
      *) warn 'Неверный пункт.'; continue ;;
    esac
    if [[ ! -s "$file" ]]; then
      warn "Профиль ещё не создан: $file"
      warn 'Сначала открой пункт «Транспорт / профили».'
      pause
      continue
    fi
    echo
    echo '================ КОПИРУЙ JSON НИЖЕ ================'
    warn 'JSON может содержать REALITY privateKey. Не публикуй его.'
    cat "$file"
    echo
    echo '================ КОНЕЦ JSON ========================'
    pause
  done
}

signature_menu(){
  sync_next_sources
  local c
  while true; do
    cat <<'MENU'

XHTTP signature
 [1] Применить / создать стабильную per-node signature
 [2] Показать сохранённую signature
 [3] Снять signature с XHTTP profile
 [0] Назад
MENU
    printf 'Выбор: '; read -r c < "$TTY" || true
    case "$c" in
      1) "$SIGNATURE" apply; pause ;;
      2) "$SIGNATURE" show; pause ;;
      3) "$SIGNATURE" revert; pause ;;
      0|'') return 0 ;;
      *) warn 'Неверный пункт.' ;;
    esac
  done
}

runtime_menu(){
  sync_next_sources
  local c
  while true; do
    cat <<'MENU'

Runtime guards / repair
 [1] Восстановить Hysteria2 cert mount
 [2] Восстановить RKN guard
 [3] Синхронизировать RKN self-heal watcher
 [4] Удалить RKN self-heal watcher
 [0] Назад
MENU
    printf 'Выбор: '; read -r c < "$TTY" || true
    case "$c" in
      1) "$GUARDS" restore-hysteria; pause ;;
      2) "$GUARDS" restore-rkn; pause ;;
      3) "$GUARDS" sync-rkn-watch; pause ;;
      4) "$GUARDS" remove-rkn-watch; pause ;;
      0|'') return 0 ;;
      *) warn 'Неверный пункт.' ;;
    esac
  done
}

base_manage_menu(){
  sync_next_sources
  local c fn
  while true; do
    cat <<'MENU'

Базовое управление Remnanode
 [1] Первоначальная настройка
 [2] Смена домена / SSL
 [3] Обновить Xray/rw-core
 [4] Изменить IP панели
 [5] Управление IPv6
 [6] Диагностика и логи
 [7] Клиентские порты Xray/UFW
 [8] Сменить маскировочный шаблон
 [9] Мульти-тесты сервера
 [0] Назад

Удаление из legacy-меню намеренно не вынесено сюда: старый uninstall делает global UFW reset.
MENU
    printf 'Выбор: '; read -r c < "$TTY" || true
    case "$c" in
      1) fn=run_initial_setup ;;
      2) fn=change_domain_and_ssl ;;
      3) fn=update_xray_core_only ;;
      4) fn=change_panel_ip ;;
      5) fn=manage_ipv6_menu ;;
      6) fn=diagnose_and_logs ;;
      7) fn=manage_xray_ports ;;
      8) fn=change_decoy_template_menu ;;
      9) fn=run_server_multitests ;;
      0|'') return 0 ;;
      *) warn 'Неверный пункт.'; continue ;;
    esac
    legacy_call "$fn"
  done
}

show_status(){
  sync_next_sources
  echo '================ REMNANODE NEXT STATUS ================'
  printf 'Transport : %s\n' "$(cat "$APP_DIR/.transport" 2>/dev/null || echo 'не выбран')"
  printf 'Domain    : %s\n' "$(cat "$APP_DIR/.node_domain" 2>/dev/null || echo 'не задан')"
  printf 'Node      : '
  if command -v docker >/dev/null 2>&1; then docker ps --filter name='^/remnanode$' --format '{{.Status}}' 2>/dev/null | head -1 || true; else echo 'docker отсутствует'; fi
  printf 'Nginx     : '
  if command -v docker >/dev/null 2>&1; then docker ps --filter name='^/remnawave-nginx$' --format '{{.Status}}' 2>/dev/null | head -1 || true; else echo 'docker отсутствует'; fi
  echo 'Listeners :'
  ss -lntup 2>/dev/null | grep -E '(:443|:2222)[[:space:]]' || true
  echo 'Profiles  :'
  find "$APP_DIR/remnawave-profiles" -maxdepth 1 -type f -name '*.json' -printf '  %f\n' 2>/dev/null | sort || true
  if [[ -x "$RKN" ]]; then
    echo 'RKN       :'
    "$RKN" status || true
  fi
}

backup_current(){
  [[ -d "$APP_DIR" ]] || return 0
  local stamp dst rel paths=()
  stamp="$(date +%Y%m%d-%H%M%S)"
  dst="/root/remnanode-next-backup-${stamp}.tar.gz"
  for rel in \
    opt/remnanode/.env \
    opt/remnanode/.node_domain \
    opt/remnanode/.node_name \
    opt/remnanode/.panel_ip \
    opt/remnanode/.protocol \
    opt/remnanode/.transport \
    opt/remnanode/.camouflage_mode \
    opt/remnanode/.reality_sni \
    opt/remnanode/.reality_target \
    opt/remnanode/.xhttp_path \
    opt/remnanode/reality.env \
    opt/remnanode/xhttp-signature.json \
    opt/remnanode/docker-compose.yml \
    opt/remnanode/nginx.conf \
    opt/remnanode/certs \
    opt/remnanode/remnawave-profiles
  do
    [[ -e "/$rel" ]] && paths+=("$rel")
  done
  ((${#paths[@]})) || return 0
  tar -C / -czf "$dst" "${paths[@]}"
  chmod 0600 "$dst"
  ok "Backup конфигурации → $dst"
}

safe_clean_impl(){
  sync_next_sources
  backup_current
  "$GUARDS" remove-rkn-watch >/dev/null 2>&1 || true
  "$RKN" uninstall >/dev/null 2>&1 || true

  if [[ -f "$APP_DIR/docker-compose.yml" ]] && command -v docker >/dev/null 2>&1; then
    (cd "$APP_DIR" && docker compose down) || true
  fi
  if command -v docker >/dev/null 2>&1; then
    docker rm -f remnanode remnawave-nginx >/dev/null 2>&1 || true
  fi

  rm -rf "$APP_DIR"
  for link in "$CLI" /usr/local/bin/remnanode; do
    if [[ -L "$link" ]]; then
      target="$(readlink -f "$link" 2>/dev/null || true)"
      [[ "$target" == "$APP_DIR"/* ]] && rm -f "$link"
    fi
  done
  ok 'Удалён только Remnanode/NEXT stack. Docker как пакет, SSH, маршруты, DNS и чужие контейнеры не тронуты.'
}

safe_clean(){
  warn 'Будут удалены локальные Remnanode/Nginx/NEXT/RKN файлы этой ноды.'
  warn 'Перед удалением конфигурация будет сохранена в /root/remnanode-next-backup-*.tar.gz.'
  printf 'Для продолжения введи YES (0 = назад): '
  local answer; read -r answer < "$TTY" || true
  [[ "$answer" == YES ]] || { say 'Отменено.'; return 0; }
  safe_clean_impl
}

run_install(){
  sync_next_sources
  if [[ ! -s "$APP_DIR/docker-compose.yml" ]] || ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
    legacy_call run_initial_setup
    sync_next_sources
  else
    ok 'Базовая Remnanode уже установлена — сохраняю её и перехожу к NEXT transport.'
  fi

  "$SELFSTEAL" ensure || warn 'SelfSteal site требует внимания.'
  "$TRANSPORT"
  post_transport

  local answer
  printf 'Открыть RKN SAFE menu сейчас? [y/N]: '
  read -r answer < "$TTY" || true
  [[ "$answer" =~ ^[Yy]$ ]] && "$RKN" menu || true
  "$GUARDS" sync-rkn-watch >/dev/null 2>&1 || true
  show_status
}

run_reinstall(){
  warn 'Переустановка сначала сделает backup, затем удалит только текущий Remnanode/NEXT stack.'
  printf 'Для продолжения введи REINSTALL (0 = назад): '
  local answer; read -r answer < "$TTY" || true
  [[ "$answer" == REINSTALL ]] || { say 'Отменено.'; return 0; }
  sync_next_sources
  safe_clean_impl
  run_install
}

main_menu(){
  sync_next_sources
  local c
  while true; do
    cat <<'MENU'

REMNANODE NEXT — main
────────────────────────────────────────────────────────────
 [1]  Установка / продолжить настройку NEXT
 [2]  Транспорт / профили (XHTTP / RAW / Hysteria2 / combined)
 [3]  Профили для копипасты в Remnawave
 [4]  SelfSteal / маскировочный сайт
 [5]  XHTTP signature
 [6]  РКН защита — SAFE scanner guard
 [7]  Runtime repair / guards
 [8]  Базовое управление Remnanode
 [9]  Статус
 [10] Safe clean текущей ноды
 [11] Safe reinstall
 [0]  Выход
────────────────────────────────────────────────────────────
MENU
    printf 'Выбор: '; read -r c < "$TTY" || true
    case "$c" in
      1) run_install; pause ;;
      2) transport_menu; pause ;;
      3) copy_profile_menu ;;
      4) "$SELFSTEAL" choose; pause ;;
      5) signature_menu ;;
      6) "$RKN" menu ;;
      7) runtime_menu ;;
      8) base_manage_menu ;;
      9) show_status; pause ;;
      10) safe_clean; pause ;;
      11) run_reinstall; pause ;;
      0|'') return 0 ;;
      *) warn 'Неверный пункт.' ;;
    esac
  done
}

main(){
  need_root
  case "${1:-menu}" in
    menu|'') main_menu ;;
    install|install-next) run_install ;;
    reinstall|full-reinstall) run_reinstall ;;
    clean) safe_clean ;;
    transport) sync_next_sources; shift; "$TRANSPORT" "$@"; post_transport ;;
    profile|profiles) copy_profile_menu ;;
    selfsteal) sync_next_sources; shift; "$SELFSTEAL" "${1:-choose}" "${2:-}" ;;
    rkn) sync_next_sources; shift; "$RKN" "${1:-menu}" ;;
    signature) sync_next_sources; shift; "$SIGNATURE" "${1:-apply}" ;;
    runtime) sync_next_sources; shift; "$GUARDS" "$@" ;;
    status) show_status ;;
    sync-source) sync_next_sources ;;
    *) die 'Использование: full-clean-reinstall.sh [menu|install|reinstall|clean|transport|profiles|selfsteal|rkn|signature|runtime|status|sync-source]' ;;
  esac
}

main "$@"
