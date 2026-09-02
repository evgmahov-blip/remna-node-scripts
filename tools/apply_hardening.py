#!/usr/bin/env python3
from pathlib import Path


def replace(path, old, new):
    p = Path(path)
    s = p.read_text()
    if old not in s:
        raise SystemExit(f"expected block not found in {path}: {old[:80]!r}")
    p.write_text(s.replace(old, new, 1))

mgr = "install-caddy-node-reality-stream.sh"
prot = "protection-manager.sh"

replace(mgr,
'''HANDOFF_TIMER=/etc/systemd/system/remna-reality-handoff.timer\nSTREAM_SOURCES=(''',
'''HANDOFF_TIMER=/etc/systemd/system/remna-reality-handoff.timer\nHANDOFF_COOLDOWN=/run/remna-reality-handoff.cooldown\nHANDOFF_COOLDOWN_SECONDS=${HANDOFF_COOLDOWN_SECONDS:-300}\nSTREAM_SOURCES=(''')

replace(mgr, 'curl -kfsSL --connect-timeout 5 --max-time 15 --range 0-131071',
             'curl -fsSL --connect-timeout 5 --max-time 15 --range 0-131071')

replace(mgr,
'''container_has_secret(){\n  $SUDO docker exec remnanode sh -c '[ -n "$SECRET_KEY" ]' >/dev/null 2>&1\n}\n''',
'''container_secret_matches(){\n  local expected actual\n  [ -f "$NODE_ENV" ] || return 1\n  expected="$(awk -F= '/^SECRET_KEY=/{print substr($0,index($0,"=")+1); exit}' "$NODE_ENV" 2>/dev/null)"\n  [ -n "$expected" ] || return 1\n  actual="$($SUDO docker exec remnanode sh -c 'printf %s "$SECRET_KEY"' 2>/dev/null)" || return 1\n  [ "$actual" = "$expected" ]\n  unset expected actual\n}\n''')

replace(mgr,
'''  [ -f "$compose" ] || return 0\n\n  inline="$(awk ''',
'''  [ -f "$compose" ] || return 0\n\n  # The legacy AWK migration is intentionally allowed only for a single-service\n  # compose file. This prevents accidentally rewriting secrets/capabilities of\n  # unrelated services when operators extend the stack.\n  local services service_count\n  services="$(cd "$NODE_DIR" && $SUDO docker compose config --services 2>/dev/null)" || { warn "Не удалось разобрать compose; изменения не применяю."; return 1; }\n  service_count="$(printf '%s\\n' "$services" | sed '/^[[:space:]]*$/d' | wc -l)"\n  if [ "$service_count" -ne 1 ] || ! printf '%s\\n' "$services" | grep -qx remnanode; then\n    warn "Compose содержит не только remnanode. Автоматическую AWK-миграцию отключаю во избежание изменения чужих сервисов."\n    return 1\n  fi\n\n  inline="$(awk ''')

replace(mgr, '    container_has_secret || need_recreate=1', '    container_secret_matches || need_recreate=1')
replace(mgr, '  container_has_secret || die "SECRET_KEY не попал внутрь remnanode. Проверь $NODE_ENV и env_file в compose."',
             '  container_secret_matches || die "SECRET_KEY внутри remnanode не совпадает с $NODE_ENV. Проверь env_file и пересоздание контейнера."')

replace(mgr,
'''node_has_443_conflict(){\n  command -v docker >/dev/null 2>&1 || return 1\n  $SUDO docker logs --since 3m remnanode 2>&1 | tr -d '\\000' | \\\n    grep -aEq 'failed to listen TCP on 443.*address already in use|listen tcp 0\\.0\\.0\\.0:443: bind: address already in use|Xray Core process is not running anymore.*exitcode 255'\n}\n''',
'''node_has_443_conflict(){\n  command -v docker >/dev/null 2>&1 || return 1\n  # Keep the observation window shorter than the retry cooldown so an old log\n  # line cannot trigger an endless Caddy 443 <-> 8443 flap.\n  $SUDO docker logs --since 20s remnanode 2>&1 | tr -d '\\000' | \\\n    grep -aEq 'failed to listen TCP on 443.*address already in use|listen tcp 0\\.0\\.0\\.0:443: bind: address already in use|Xray Core process is not running anymore.*exitcode 255'\n}\n\nhandoff_in_cooldown(){\n  local until now\n  [ -r "$HANDOFF_COOLDOWN" ] || return 1\n  read -r until < "$HANDOFF_COOLDOWN" || return 1\n  [[ "$until" =~ ^[0-9]+$ ]] || return 1\n  now="$(date +%s)"\n  [ "$now" -lt "$until" ]\n}\n\nset_handoff_cooldown(){\n  local until=$(( $(date +%s) + HANDOFF_COOLDOWN_SECONDS ))\n  printf '%s\\n' "$until" | $SUDO tee "$HANDOFF_COOLDOWN" >/dev/null\n}\n\nclear_handoff_cooldown(){ $SUDO rm -f "$HANDOFF_COOLDOWN" 2>/dev/null || true; }\n''')

replace(mgr,
'''  [ -s "$CADDY_REALITY" ] || return 0\n\n  if rw_core_on_443; then''',
'''  [ -s "$CADDY_REALITY" ] || return 0\n\n  if rw_core_on_443; then\n    clear_handoff_cooldown''')

replace(mgr,
'''  if caddy_public_443 && node_has_443_conflict; then\n    warn "Xray получил профиль, но :443 занят Caddy — выполняю автоматический handoff Caddy → 127.0.0.1:8443."''',
'''  if caddy_public_443 && node_has_443_conflict; then\n    if handoff_in_cooldown; then\n      warn "Handoff недавно завершился rollback; повтор пропущен до окончания cooldown."\n      return 0\n    fi\n    warn "Xray получил профиль, но :443 занят Caddy — выполняю автоматический handoff Caddy → 127.0.0.1:8443."''')

replace(mgr,
'''      if rw_core_on_443; then\n        ok "REALITY поднялся автоматически: rw-core :443, Caddy 127.0.0.1:8443."\n        return 0''',
'''      if rw_core_on_443; then\n        clear_handoff_cooldown\n        ok "REALITY поднялся автоматически: rw-core :443, Caddy 127.0.0.1:8443."\n        return 0''')

replace(mgr,
'''    warn "После handoff rw-core не занял :443 за ${wait} сек — возвращаю публичный Caddy."\n    switch_caddy_to_public || true\n    return 1''',
'''    warn "После handoff rw-core не занял :443 за ${wait} сек — возвращаю публичный Caddy."\n    switch_caddy_to_public || true\n    set_handoff_cooldown\n    warn "Повторный handoff заблокирован на ${HANDOFF_COOLDOWN_SECONDS} сек, чтобы исключить flap по старой записи лога."\n    return 1''')

replace(mgr,
'''  ensure_node_compose >/dev/null 2>&1 || true\n  install_handoff_watcher >/dev/null 2>&1 || true\n  auto_handoff_once || true\n  ensure_telemt_route || true\n\n''',
'''  # IMPORTANT: diagnose is strictly read-only. Repairs belong to selftest/repair.\n\n''')

replace(mgr,
'''    echo '                Менеджер попытался автоматически передать :443 от Caddy к rw-core.' ''',
'''    echo '                Для исправления запусти selftest/repair: они могут безопасно выполнить handoff.' ''')

replace(mgr, '  bash <(cat "$CORE") "$@"', '  bash "$CORE" "$@"')

# Never execute settings.conf as shell code. Parse an allow-list as inert data.
replace(prot,
'''load_conf(){\n  write_defaults\n  # shellcheck disable=SC1090\n  . "$CONF"\n  PANEL_IP=${PANEL_IP:-}\n  ENABLE_TSPU=${ENABLE_TSPU:-1}\n  ENABLE_GOV=${ENABLE_GOV:-1}\n  ENABLE_GEOIP=${ENABLE_GEOIP:-0}\n  FILTER_PORTS=${FILTER_PORTS:-443,18443,5222,5223,8530}\n  GEO_COUNTRIES=${GEO_COUNTRIES:-}\n}\n''',
'''load_conf(){\n  write_defaults\n  PANEL_IP=\n  ENABLE_TSPU=1\n  ENABLE_GOV=1\n  ENABLE_GEOIP=0\n  FILTER_PORTS=443,18443,5222,5223,8530\n  GEO_COUNTRIES=\n  local key value\n  while IFS='=' read -r key value; do\n    case "$key" in\n      PANEL_IP|ENABLE_TSPU|ENABLE_GOV|ENABLE_GEOIP|FILTER_PORTS|GEO_COUNTRIES) printf -v "$key" '%s' "$value" ;;\n    esac\n  done < "$CONF"\n}\n''')

replace(prot,
'''            n=ipaddress.ip_network(v,strict=False)\n            if n.version==4: out.add(str(n))''',
'''            n=ipaddress.ip_network(v,strict=False)\n            # A poisoned upstream feed must never be able to block nearly the\n            # whole IPv4 Internet. /0../7 are rejected as unsafe aggregates.\n            if n.version==4 and n.prefixlen >= 8: out.add(str(n))''')

# Validate config values before persisting them.
replace(prot,
'''set_conf(){\n  local key=$1 value=$2 tmp\n  tmp=$(mktemp)''',
'''set_conf(){\n  local key=$1 value=$2 tmp\n  case "$key" in\n    PANEL_IP) [ -z "$value" ] || valid_ip "$value" || die "Некорректный PANEL_IP" ;;\n    ENABLE_TSPU|ENABLE_GOV|ENABLE_GEOIP) [[ "$value" =~ ^[01]$ ]] || die "Для $key допустимы только 0 или 1" ;;\n    FILTER_PORTS) valid_ports "$value" || die "Некорректный список портов" ;;\n    GEO_COUNTRIES) [[ "$value" =~ ^([A-Za-z]{2})(,[A-Za-z]{2})*$|^$ ]] || die "GEO_COUNTRIES: ожидается список ISO-кодов, например FI,DE,NL" ;;\n    *) die "Запрещён неизвестный ключ конфигурации: $key" ;;\n  esac\n  tmp=$(mktemp)''')

print("hardening patch applied")
