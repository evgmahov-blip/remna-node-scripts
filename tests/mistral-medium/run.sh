#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# F-07: safe clean backs up and uninstalls owned protection before deleting app files.
grep -Fq 'opt/remna-protection' full-clean-reinstall.sh
grep -Fq 'var/log/remna-protection' full-clean-reinstall.sh
python3 - <<'PY'
from pathlib import Path
s=Path('full-clean-reinstall.sh').read_text()
b=s.split('safe_clean_impl(){',1)[1].split('\n}',1)[0]
assert '"$PROTECTION" uninstall' in b
assert b.index('"$PROTECTION" uninstall') < b.index('rm -rf "$APP_DIR"')
assert 'rm -rf /opt/remna-protection /var/log/remna-protection' in b
PY

# F-08: Remnawave image is versioned and pinned by the multi-arch OCI index digest.
grep -Fq 'NODE_IMAGE_VERSION="3.4.1"' full-clean-reinstall.sh
grep -Fq 'NODE_IMAGE_DIGEST="sha256:0cdf386dd49f360fc885bb34bde21132e478e40f0deac62d616086ec0fa9257e"' full-clean-reinstall.sh
grep -Fq 'ghcr.io/remnawave/node:${NODE_IMAGE_VERSION}@${NODE_IMAGE_DIGEST}' full-clean-reinstall.sh
grep -Fq "! grep -R -Fq 'ghcr.io/remnawave/node:latest'" full-clean-reinstall.sh

# F-09/F-16: Telemt repair accepts its own listeners, preserves the MTProto secret,
# and correctly parses standard single-digit/multi-digit UFW rule numbers.
grep -Fq 'port_owned_by_telemt(){' next-installer/telemt-manager.sh
grep -Fq 'preserving existing MTProto secret' next-installer/telemt-manager.sh
grep -Fq 'systemctl restart telemt.service telemt-panel.service' next-installer/telemt-manager.sh
grep -Fq 'remove_protection_port' next-installer/telemt-manager.sh
grep -Fq 'Enter = сохранить текущий при repair' full-clean-reinstall.sh
! sed -n '/telemt_menu(){/,/^}/p' full-clean-reinstall.sh | grep -Fq 'Пустой пароль — установка отменена.'
ufw_one="$(bash -c 'source next-installer/telemt-manager.sh >/dev/null; printf "%s\n" "[ 1] 8443/tcp ALLOW IN Anywhere # Telemt MTProto" | ufw_owned_rule_number 8443')"
ufw_twelve="$(bash -c 'source next-installer/telemt-manager.sh >/dev/null; printf "%s\n" "[12] 8443/tcp ALLOW IN Anywhere # Telemt MTProto" | ufw_owned_rule_number 8443')"
test "$ufw_one" = 1
test "$ufw_twelve" = 12

# F-10: PANEL_IP is explicit/saved only; established TCP peers are never trusted as panel identity.
! grep -Fq 'ss -tn state established' next-installer/legacy-rebuild-manager.sh
grep -Fq '/opt/remna-protection/settings.conf' next-installer/legacy-rebuild-manager.sh

# F-11: temporary node secret is in tmpfs; successful runs remove it while failed
# pre-base runs retain only the tmpfs copy so resume still works.
grep -Fq 'SECRET_FILE="${SECRET_FILE:-/run/remna-managed-rebuild-secret}"' next-installer/legacy-rebuild-manager.sh
grep -Fq 'trap cleanup_secret_on_exit EXIT' next-installer/legacy-rebuild-manager.sh
grep -Fq 'tmpfs resume secret retained' next-installer/legacy-rebuild-manager.sh

# IPQuality: only rc=0/known IPv4-only rc=1 plus expected JSON schema are accepted.
grep -Fq '(( rc == 0 || rc == 1 ))' next-installer/server-multitest.sh
grep -Fq '(.Info.ASN != null)' next-installer/server-multitest.sh

# F-13: destructive migration/rebuild backup paths fail closed and archives are verified.
grep -Fq 'backup archive creation failed' next-installer/legacy-rebuild-manager.sh
grep -Fq 'backup archive verification failed' next-installer/legacy-rebuild-manager.sh
grep -Fq 'Recovery backup archive creation failed' next-installer/existing-node-v2-cleanup.sh
grep -Fq 'Recovery backup archive verification failed' next-installer/existing-node-v2-cleanup.sh

# F-14: protection logs are private and no longer log the panel address.
grep -Fq 'chmod 0700 "$BASE" "$DATA" "$LOGDIR"' security/remna-security.sh
grep -Fq 'chmod 0600 "$ACTION_LOG" "$UPDATE_LOG"' security/remna-security.sh
! grep -Fq 'panel=$PANEL_IP' security/remna-security.sh

# F-17: no global hostname mutation. Caddy is stopped only after the main
# node Caddyfile ownership test succeeds; unrelated Caddy is reload-only.
! grep -Fq 'hostnamectl set-hostname' next-installer/legacy-rebuild-manager.sh
grep -Fq 'if (( main_owned )) && systemctl is-active --quiet caddy' next-installer/existing-node-v2-cleanup.sh
grep -Fq "systemctl stop caddy >/dev/null 2>&1 || die 'Owned Caddy runtime could not be stopped.'" next-installer/existing-node-v2-cleanup.sh
! grep -Fq 'run_quiet systemctl stop caddy' next-installer/existing-node-v2-cleanup.sh
grep -Fq 'global stop Caddy не выполнялся без подтверждённого ownership' next-installer/existing-node-v2-cleanup.sh

echo 'PASS Mistral medium hardening F-07/F-08/F-09/F-10/F-11/F-13/F-14/F-16/F-17'
