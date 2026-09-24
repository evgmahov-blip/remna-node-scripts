#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# F-01: rebuild/resume must resolve and validate the installed launcher before backup/cleanup.
grep -Fq 'FULL="${FULL:-/usr/local/libexec/remnanode-next.sh}"' next-installer/legacy-rebuild-manager.sh
python3 - <<'PY'
from pathlib import Path
s=Path('next-installer/legacy-rebuild-manager.sh').read_text()
for fn in ('rebuild','resume'):
    block=s.split(f'{fn}(){{',1)[1].split('\n}',1)[0]
    assert '[ -s "$FULL" ]' in block
    if fn == 'rebuild':
        assert block.index('[ -s "$FULL" ]') < block.index('make_backup')
PY

# F-02: no global nginx site wipe/disable in managed rebuild.
! grep -Fq 'rm -f /etc/nginx/sites-enabled/*' next-installer/legacy-rebuild-manager.sh
! grep -Fq 'systemctl disable --now nginx' next-installer/legacy-rebuild-manager.sh
grep -Fq 'grep -Fq "$old_domain" "$f"' next-installer/legacy-rebuild-manager.sh

# F-03: current protection + panel guard is mandatory in default install path.
python3 - <<'PY'
from pathlib import Path
s=Path('full-clean-reinstall.sh').read_text()
b=s.split('run_install(){',1)[1].split('\n}',1)[0]
assert 'PANEL_IP_ENV="$panel_ip" "$PROTECTION" install' in b
assert "refusing to leave TCP/2222 without current protection" in b
PY

# F-05: node runtime is gone before old 2222 protection is removed.
python3 - <<'PY'
from pathlib import Path
s=Path('next-installer/existing-node-v2-cleanup.sh').read_text()
b=s.split('main(){',1)[1].split('\n}',1)[0]
assert b.index('stop_node_runtime') < b.index('remove_legacy_firewall') < b.index('remove_node_runtime_files')
PY

# F-06: bad FILTER_PORTS fails before any rules are rendered.
PYTHONPATH="$ROOT" python3 - <<'PY'
import tempfile
from pathlib import Path
from security import remna_sec
with tempfile.TemporaryDirectory() as td:
    base=Path(td)
    (base/'settings.conf').write_text('PANEL_IP=203.0.113.10\nFILTER_PORTS=\nENABLE_TSPU=1\nENABLE_GOV=1\nENABLE_SCANNERS=1\n')
    (base/'data').mkdir()
    try:
        remna_sec.build_plan(base)
    except ValueError as e:
        assert 'FILTER_PORTS' in str(e)
    else:
        raise SystemExit('invalid FILTER_PORTS was accepted')
PY

# F-04: staging chain is populated+hooked before canonical chain is flushed;
# on canonical rebuild failure the staging hook is deliberately retained.
PYTHONPATH="$ROOT" python3 - <<'PY'
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from security import remna_sec

with tempfile.TemporaryDirectory() as td:
    base=Path(td); (base/'data').mkdir()
    (base/'settings.conf').write_text('PANEL_IP=203.0.113.10\nFILTER_PORTS=443,8443\nENABLE_TSPU=0\nENABLE_GOV=0\nENABLE_SCANNERS=0\n')
    plan=remna_sec.build_plan(base)

calls=[]
stage_hook=[]

def fake_run(cmd, *args, **kwargs):
    cmd=list(cmd); calls.append(cmd)
    # -C checks: canonical hook exists initially, staging hook exists after insert.
    if len(cmd)>=3 and cmd[1]=='-C':
        if any('_STG_' in x for x in cmd):
            exists=bool(stage_hook)
            return SimpleNamespace(returncode=0 if exists else 1)
        return SimpleNamespace(returncode=0 if not any(c[:4]==[cmd[0],'-D','INPUT','-j'] and c[-1]==remna_sec.CHAIN for c in calls[:-1]) else 1)
    if len(cmd)>=6 and cmd[1:5]==['-I','INPUT','1','-j'] and '_STG_' in cmd[5]:
        stage_hook[:] = [cmd[5]]
    # Fail while rebuilding canonical chain, after staging is active.
    if len(cmd)>=3 and cmd[1]=='-A' and cmd[2]==remna_sec.CHAIN:
        raise RuntimeError('synthetic canonical rebuild failure')
    return SimpleNamespace(returncode=0)

with patch.object(remna_sec.subprocess, 'run', side_effect=fake_run):
    try:
        remna_sec.execute_live(plan,{})
    except RuntimeError as e:
        assert 'synthetic' in str(e)
    else:
        raise SystemExit('expected synthetic failure')

stage_add=[i for i,c in enumerate(calls) if len(c)>=3 and c[1]=='-A' and '_STG_' in c[2]]
stage_insert=[i for i,c in enumerate(calls) if len(c)>=6 and c[1:5]==['-I','INPUT','1','-j'] and '_STG_' in c[5]]
canon_flush=[i for i,c in enumerate(calls) if c[:3]==['iptables','-F',remna_sec.CHAIN]]
stage_delete=[c for c in calls if len(c)>=6 and c[1:5]==['-D','INPUT','-j'] and '_STG_' in c[5]]
assert stage_add and stage_insert and canon_flush
assert max(stage_add) < stage_insert[0] < canon_flush[0]
assert not stage_delete, 'staging hook was removed after canonical failure'
PY

echo 'PASS mistral blockers F-01..F-06'
