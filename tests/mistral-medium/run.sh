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

# F-09/F-16: Telemt repair accepts its own listeners and preserves the MTProto secret.
grep -Fq 'port_owned_by_telemt(){' next-installer/telemt-manager.sh
grep -Fq 'preserving existing MTProto secret' next-installer/telemt-manager.sh
grep -Fq 'systemctl restart telemt.service telemt-panel.service' next-installer/telemt-manager.sh
grep -Fq 'remove_protection_port' next-installer/telemt-manager.sh

# F-10: PANEL_IP is explicit/saved only; established TCP peers are never trusted as panel identity.
! grep -Fq 'ss -tn state established' next-installer/legacy-rebuild-manager.sh
grep -Fq '/opt/remna-protection/settings.conf' next-installer/legacy-rebuild-manager.sh

# F-11: temporary node secret is in tmpfs and removed by traps.
grep -Fq 'SECRET_FILE="${SECRET_FILE:-/run/remna-managed-rebuild-secret}"' next-installer/legacy-rebuild-manager.sh
grep -Fq 'trap cleanup_secret EXIT HUP INT TERM' next-installer/legacy-rebuild-manager.sh

# F-13: destructive migration/rebuild backup paths fail closed and archives are verified.
grep -Fq 'backup archive creation failed' next-installer/legacy-rebuild-manager.sh
grep -Fq 'backup archive verification failed' next-installer/legacy-rebuild-manager.sh
grep -Fq 'Recovery backup archive creation failed' next-installer/existing-node-v2-cleanup.sh
grep -Fq 'Recovery backup archive verification failed' next-installer/existing-node-v2-cleanup.sh

# F-14: protection logs are private and no longer log the panel address.
grep -Fq 'chmod 0700 "$BASE" "$DATA" "$LOGDIR"' security/remna-security.sh
grep -Fq 'chmod 0600 "$ACTION_LOG" "$UPDATE_LOG"' security/remna-security.sh
! grep -Fq 'panel=$PANEL_IP' security/remna-security.sh

# F-17: no global hostname change and no global Caddy stop during managed migration.
! grep -Fq 'hostnamectl set-hostname' next-installer/legacy-rebuild-manager.sh
! grep -Fq 'systemctl stop caddy' next-installer/existing-node-v2-cleanup.sh
grep -Fq 'global stop Caddy не выполнялся' next-installer/existing-node-v2-cleanup.sh

echo 'PASS Mistral medium hardening F-07/F-08/F-09/F-10/F-11/F-13/F-14/F-16/F-17'
