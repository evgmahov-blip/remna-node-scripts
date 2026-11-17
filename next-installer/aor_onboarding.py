#!/usr/bin/env python3
"""Offline, stateless contracts for native AOR. No transport or task store."""
from contextlib import closing
from datetime import datetime
import re
import subprocess
import tempfile
import shutil
import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import sqlite3
import stat
import tarfile

STAGES = (
    ('PRECHECK', ('inventory_origin_verified', 'cloudflare_origin_verified',
                  'authorized_credentials', 'safe_remote_channel', 'service_inventory',
                  'listeners_80_443', 'dependencies', 'active_users', 'three_x_ui_type')),
    ('BACKUP_RESTORE_PROOF', ('consistent_snapshot', 'complete_recovery_bundle',
                            'checksum_verified', 'sqlite_integrity', 'restore_test',
                            'rollback_access', 'dns_snapshot', 'panel_memberships_snapshot')),
    ('STAGE_NEXT', ('exact_release', 'pinned_bootstrap', 'no_live_effects')),
    ('REVIEW_CI', ('independent_review', 'required_ci')),
    ('OWNER_GATE', ('owner_production_approval',)),
    ('CONTROLLED_CUTOVER', ('rollback_ready', 'only_3x_ui_stopped', 'port_443_released')),
    ('SETUP_NEXT', ('shared_secret_source', 'two_containers_host_network',
                    'selfsteal_unix_socket', 'unique_xhttp_path_keys', 'xhttp_signature',
                    'xray_default_mapper_empty_flow_empty', 'certbot_timer_hook',
                    'panel_only_2222', 'remna_guard_ipset', 'bbr_fq', 'nofile_65536')),
    ('REGISTER', ('approved_cloudflare', 'exact_dns', 'exact_profile', 'exact_node',
                  'exact_host', 'all_squads_preserved', 'host_allow_only_exact_squads')),
    ('VERIFY', ('isConnected', 'tcp_443_external', 'tls_external', 'client_connection',
                'active_local_profile_equal', 'certbot_dry_run', 'systemd_health',
                'firewall_safe', 'rollback_available', 'fresh_all_squads_equal')),
)


def require(condition, code):
    if not condition:
        raise ValueError(code)


def continuation(evidence, task, release, operation):
    """Evidence is supplied/attested by AOR, never confers execution authority."""
    require(isinstance(evidence, dict), 'E_SCHEMA')
    require(evidence.get('schema') == 'remna.aor-evidence.v1', 'E_SCHEMA')
    require(evidence.get('task_id') == task and evidence.get('release') == release
            and evidence.get('operation_id') == operation, 'E_BINDING')
    require(len(release) == 40 and all(c in '0123456789abcdef' for c in release), 'E_RELEASE')
    stages = evidence.get('stages', {})
    require(isinstance(stages, dict), 'E_STAGES')
    effect_ids = set()
    for stage, checks in STAGES:
        record = stages.get(stage, {})
        require(isinstance(record, dict) and isinstance(record.get('checks', {}), dict), 'E_RECORD')
        if not (record.get('aor_attestation_ref') and record.get('effect_id')
                and record.get('observed_at') and record.get('artifact_sha256')):
            return {'status': 'pending', 'stage': stage, 'missing': ['bound_aor_evidence']}
        require(re.fullmatch(r'[0-9a-f]{64}', record['artifact_sha256']) is not None, 'E_DIGEST')
        try:
            timestamp = datetime.fromisoformat(record['observed_at'].replace('Z', '+00:00'))
            require(timestamp.tzinfo is not None, 'E_TIMESTAMP')
        except (TypeError, ValueError):
            raise ValueError('E_TIMESTAMP') from None
        require(record['effect_id'] not in effect_ids, 'E_EFFECT_DUPLICATE')
        effect_ids.add(record['effect_id'])
        missing = [c for c in checks if record.get('checks', {}).get(c) is not True]
        if missing:
            return {'status': 'pending', 'stage': stage, 'missing': missing}
    return {'status': 'evidence_ready_for_aor_verification', 'stage': 'VERIFY'}


def reconcile(existing, desired):
    """Never POST when an object exists; ambiguous matches or drift fail closed."""
    require(len(existing) <= 1, 'E_DUPLICATE')
    if not existing:
        return {'action': 'create', 'desired': desired}
    require(all(existing[0].get(k) == v for k, v in desired.items()), 'E_EFFECT_DRIFT')
    return {'action': 'reuse', 'uuid': existing[0]['uuid']}


def squad_model(squads):
    require(isinstance(squads, list) and squads, 'E_SQUADS_EMPTY_OR_DUPLICATE')
    result = {}
    for squad in squads:
        uid = squad['uuid']
        require(isinstance(uid, str) and uid and uid not in result, 'E_SQUADS_EMPTY_OR_DUPLICATE')
        inbounds = squad['inbounds']
        require(isinstance(inbounds, list), 'E_INBOUNDS')
        ids = [item['uuid'] if isinstance(item, dict) else item for item in inbounds]
        require(all(isinstance(i, str) and i for i in ids) and len(set(ids)) == len(ids), 'E_INBOUNDS')
        count = squad.get('info', {}).get('membersCount')
        require(type(count) is int and count >= 0, 'E_MEMBERS_COUNT')
        result[uid] = (set(ids), count)
    return result


def squad_changes(before, inbound, host_squads, host_mode):
    """inbound is the panel inbound UUID, never its tag. No user PATCH fields."""
    require(isinstance(inbound, str) and bool(inbound), 'E_INBOUND_UUID')
    model = squad_model(before)
    require(host_mode == 'ALLOW_ONLY' and set(host_squads) == set(model)
            and len(host_squads) == len(model), 'E_HOST_SQUADS')
    return [{'uuid': uid, 'inbounds': sorted(ids | {inbound})}
            for uid, (ids, _) in model.items()]


def verify_squads(before, after, inbound):
    old, new = squad_model(before), squad_model(after)
    require(old.keys() == new.keys(), 'E_SQUAD_RACE')
    for uid, (ids, count) in old.items():
        require(new[uid][0] == ids | {inbound}, 'E_INBOUNDS')
        require(new[uid][1] == count, 'E_USERS')
    # Equal counts detect count changes, not replacement of one member by another.
    return {'squads_count': len(old), 'member_counts_preserved': True}


def origin(inventory, cloudflare, observed):
    addresses = [str(ipaddress.ip_address(x)) for x in (inventory, cloudflare, observed)]
    require(len(set(addresses)) == 1, 'E_ORIGIN_MISMATCH')
    return addresses[0]


RECOVERY_CATEGORIES = ('database', 'client_metadata', 'app_config_volumes', 'tls_acme',
    'reverse_proxy', 'ssh', 'firewall', 'routes', 'containers_units', 'dns', 'panel_memberships')


def digest_file(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def owner_uid(path):
    return Path(path).stat().st_uid


def private_parent(path):
    st = Path(path).parent.stat()
    require(owner_uid(Path(path).parent) == 0 and stat.S_IMODE(st.st_mode) == 0o700, 'E_PRIVATE_DIRECTORY')


def private_json(path, value):
    private_parent(path)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream, sort_keys=True)


def safe_path(root, name):
    p = Path(name)
    require(bool(p.parts) and not p.is_absolute() and '..' not in p.parts, 'E_PATH')
    current = root
    for part in p.parts:
        current = current / part
        require(not current.is_symlink(), 'E_MISSING_OR_SYMLINK')
    require(current.exists() and current.resolve().is_relative_to(root), 'E_PATH')
    return current


def sqlite_check(db):
    require(not Path(str(db) + '-wal').exists(), 'E_SQLITE_WAL_NEEDS_CONSOLIDATED_SNAPSHOT')
    require(not Path(str(db) + '-journal').exists(), 'E_SQLITE_JOURNAL_NEEDS_CONSOLIDATED_SNAPSHOT')
    with closing(sqlite3.connect(db.as_uri() + '?mode=ro&immutable=1', uri=True)) as conn:
        require(conn.execute('PRAGMA integrity_check').fetchall() == [('ok',)], 'E_SQLITE')


def recovery(snapshot, output, members, databases, coverage=None):
    """Package only a consistent read-only snapshot. No live backup or service stop."""
    require(os.geteuid() == 0, 'E_ROOT')
    snapshot = Path(snapshot).resolve(strict=True)
    require(bool(os.statvfs(snapshot).f_flag & os.ST_RDONLY), 'E_SNAPSHOT_NOT_READONLY')
    output = Path(output)
    private_parent(output)
    require(members and databases, 'E_EMPTY_RECOVERY')
    require(isinstance(coverage, dict) and set(coverage) == set(RECOVERY_CATEGORIES), 'E_COVERAGE')
    files, metadata = {}, {}
    for name in members:
        src = safe_path(snapshot, name)
        for item in ([src] if src.is_file() else [src, *src.rglob('*')]):
            require(not item.is_symlink() and (item.is_file() or item.is_dir()), 'E_SPECIAL_FILE')
            relative = str(item.relative_to(snapshot))
            info = item.stat()
            metadata[relative] = {'mode': stat.S_IMODE(info.st_mode), 'uid': info.st_uid,
                                  'gid': info.st_gid, 'directory': item.is_dir()}
            if item.is_file():
                files[relative] = digest_file(item)
    for category, entry in coverage.items():
        require(isinstance(entry, dict), 'E_COVERAGE')
        if entry.get('paths'):
            require(all(any(f == n or Path(n) in Path(f).parents for f in files)
                        for n in entry['paths']), 'E_COVERAGE_PATH')
        else:
            require(category not in ('database', 'client_metadata', 'app_config_volumes',
                    'ssh', 'firewall', 'routes', 'containers_units', 'dns', 'panel_memberships')
                    and bool(entry.get('absent_reason')), 'E_REQUIRED_COVERAGE')
    for name in databases:
        require(name in files, 'E_DB_NOT_ARCHIVED')
        sqlite_check(safe_path(snapshot, name))
    manifest = {'schema': 'remna.recovery.v1', 'files': files, 'databases': databases,
                'coverage': coverage, 'metadata': metadata, 'restore_plan': [
                    'Use independent recovery channel and isolated host/network.',
                    'Verify bundle checksum; rehearse file and SQLite restore using restore-test.',
                    'Restore original paths, ownership, modes, volumes, units and pinned image digests.',
                    'Boot old 3x-ui only in isolation; verify users/inbounds, TLS and client traffic.',
                    'AOR must attest isolated runtime proof before owner cutover approval.',
                    'On rollback stop only NEXT; restore scoped preimages with drift checks.',
                    'Start original 3x-ui; prove management access and external client traffic.']}
    require('REMNA-RECOVERY.json' not in files, 'E_RESERVED_PATH')
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'wb') as stream:
            with tarfile.open(fileobj=stream, mode='w:gz') as archive:
                for name in files:
                    archive.add(snapshot / name, arcname=name, recursive=False)
                import io
                data = json.dumps(manifest, sort_keys=True).encode()
                info = tarfile.TarInfo('REMNA-RECOVERY.json')
                info.size, info.mode = len(data), 0o600
                archive.addfile(info, io.BytesIO(data))
        checksum = digest_file(output)
        restore_test(output, checksum)
        return checksum
    except BaseException:
        output.unlink(missing_ok=True)
        raise


def restore_test(bundle, checksum):
    """Isolated file/DB rehearsal, never a claim of old-service runtime proof."""
    require(os.geteuid() == 0, 'E_ROOT')
    private_parent(bundle)
    require(digest_file(bundle) == checksum, 'E_CHECKSUM')
    with tempfile.TemporaryDirectory(prefix='remna-restore-', dir=Path(bundle).parent) as temp:
        root = Path(temp)
        with tarfile.open(bundle, 'r:gz') as archive:
            entries = archive.getmembers()
            names = [m.name for m in entries]
            require(len(names) == len(set(names)), 'E_ARCHIVE_DUPLICATE')
            for m in entries:
                p = Path(m.name)
                require(m.isfile() and not p.is_absolute() and '..' not in p.parts, 'E_ARCHIVE_PATH')
                target = root / p
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                with archive.extractfile(m) as src, target.open('xb') as dst:
                    shutil.copyfileobj(src, dst)
                target.chmod(0o600)
            manifest = json.loads((root / 'REMNA-RECOVERY.json').read_text())
            require(set(names) == set(manifest['files']) | {'REMNA-RECOVERY.json'}, 'E_MANIFEST')
            for name, checksum in manifest['files'].items():
                archived = archive.getmember(name)
                original = manifest['metadata'][name]
                require((archived.uid, archived.gid, archived.mode) ==
                        (original['uid'], original['gid'], original['mode']), 'E_METADATA')
                require(digest_file(safe_path(root, name)) == checksum, 'E_FILE_CHECKSUM')
            for name in manifest['databases']:
                sqlite_check(safe_path(root, name))
        return {'files_count': len(manifest['files']), 'databases_count': len(manifest['databases']),
                'file_restore_verified': True, 'runtime_restore_verified': False}


def preflight(database, output, runner=None):
    """Read-only target-local collection; invoke ONLY through sanctioned AOR executor.

    Raw service/container data is private. No credential values are printed.
    Identity, entitlement and snapshot consistency still need native attestations.
    """
    require(os.geteuid() == 0, 'E_ROOT')
    private_parent(output)
    def run(argv):
        if runner:
            return runner(argv)
        result = subprocess.run(argv, capture_output=True, text=True, timeout=30, check=False)
        require(result.returncode == 0, 'E_COLLECTION')
        return result.stdout
    commands = {
        'listeners': ['ss', '-H', '-lntup'],
        'sessions': ['ss', '-H', '-nt', 'state', 'established'],
        'units': ['systemctl', 'list-units', '--all', '--no-pager', '--plain'],
        'dependencies': ['systemctl', 'show', 'x-ui.service', '-p', 'Requires', '-p', 'Wants', '-p', 'After', '-p', 'FragmentPath'],
        'containers': ['docker', 'ps', '-a', '--no-trunc', '--format', '{{json .}}'],
        'firewall4': ['iptables-save'],
        'firewall6': ['ip6tables-save'],
        'ipsets': ['ipset', 'save'],
        'nftables': ['nft', 'list', 'ruleset'],
        'rules4': ['ip', '-j', '-4', 'rule', 'show'],
        'rules6': ['ip', '-j', '-6', 'rule', 'show'],
        'routes4': ['ip', '-j', '-4', 'route', 'show', 'table', 'all'],
        'routes6': ['ip', '-j', '-6', 'route', 'show', 'table', 'all'],
    }
    raw, unavailable = {}, []
    for key, argv in commands.items():
        try:
            raw[key] = run(argv)
        except (OSError, subprocess.SubprocessError, ValueError):
            unavailable.append(key)
    kinds = []
    if re.search(r'(?m)^\s*x-ui\.service\s', raw.get('units', '')):
        kinds.append('systemd')
    if re.search(r'(?i)(3x-ui|x-ui)', raw.get('containers', '')):
        kinds.append('docker')
    # Private inspect captures mounts, image IDs, restart policy and env for recovery.
    # Discovery is deliberately conservative; unrecognised deployments block PRECHECK.
    if 'containers' in raw:
        try:
            containers = [json.loads(line) for line in raw['containers'].splitlines() if line]
            ids = [item['ID'] for item in containers]
            if ids:
                require(all(re.fullmatch(r'[0-9a-f]{12,64}', i) for i in ids), 'E_CONTAINER_ID')
                raw['container_inspect'] = run(['docker', 'inspect', *ids])
        except (OSError, subprocess.SubprocessError, ValueError, KeyError):
            unavailable.append('container_inspect')
    if 'systemd' in kinds:
        try:
            raw['unit_config'] = run(['systemctl', 'cat', 'x-ui.service'])
        except (OSError, subprocess.SubprocessError, ValueError):
            unavailable.append('unit_config')
    db = Path(database).resolve(strict=True)
    # mode=ro participates in SQLite locking/WAL; immutable is unsafe for live DBs.
    with closing(sqlite3.connect(db.as_uri() + '?mode=ro', uri=True, timeout=5)) as conn:
        conn.execute('BEGIN')
        inbounds = conn.execute('SELECT settings FROM inbounds').fetchall()
        clients = []
        for (settings,) in inbounds:
            value = json.loads(settings)
            require(isinstance(value.get('clients'), list), 'E_CLIENT_SCHEMA')
            clients.extend(value['clients'])
        enabled = sum(c.get('enable') is True for c in clients)
    raw['database_counts'] = {'inbounds': len(inbounds), 'clients': len(clients), 'enabled_clients': enabled}
    raw['three_x_ui_types'] = kinds
    # Enabled clients are not proof of actively connected users. Session telemetry
    # remains private and AOR must correlate it with app-specific runtime counters.
    raw['active_users_verified'] = False
    raw['port_80_443_listeners'] = [line for line in raw.get('listeners', '').splitlines()
        if re.search(r':(?:80|443)(?:\s|$)', line)]
    raw['unavailable'] = unavailable
    private_json(output, raw)
    return {'artifact_sha256': digest_file(output), 'inbounds_count': len(inbounds),
            'clients_count': len(clients), 'enabled_clients_count': enabled,
            'topology_count': len(kinds), 'unavailable_count': len(unavailable),
            'status': 'pending_native_precheck_verification'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    c = commands.add_parser('continuation')
    c.add_argument('evidence', type=Path)
    for flag in ('task', 'release', 'operation'):
        c.add_argument('--' + flag, required=True)
    c = commands.add_parser('preflight')
    c.add_argument('--database', required=True)
    c.add_argument('--output', required=True)
    c = commands.add_parser('recovery')
    c.add_argument('--snapshot', required=True)
    c.add_argument('--output', required=True)
    c.add_argument('--inventory', type=Path, required=True)
    c = commands.add_parser('restore-test')
    c.add_argument('--bundle', required=True)
    c.add_argument('--sha256', required=True)
    c = commands.add_parser('verify-squads')
    for name in ('before', 'after', 'host'):
        c.add_argument('--' + name, type=Path, required=True)
    c.add_argument('--inbound-uuid', required=True)
    args = parser.parse_args()
    try:
        if args.command == 'continuation':
            result = continuation(json.loads(args.evidence.read_text()), args.task, args.release, args.operation)
        elif args.command == 'preflight':
            result = preflight(args.database, args.output)
        elif args.command == 'recovery':
            inventory = json.loads(args.inventory.read_text())
            checksum = recovery(args.snapshot, args.output, inventory['members'], inventory['databases'], inventory['coverage'])
            result = {'artifact_sha256': checksum}
        elif args.command == 'restore-test':
            result = restore_test(args.bundle, args.sha256)
        else:
            before, after, host = [json.loads(p.read_text()) for p in (args.before, args.after, args.host)]
            squad_changes(after, args.inbound_uuid, host['internalSquads'], host['mode'])
            result = verify_squads(before, after, args.inbound_uuid)
    except (ValueError, KeyError, TypeError, OSError, sqlite3.Error, tarfile.TarError):
        parser.exit(2, 'E_INVALID_INPUT_OR_PROOF\n')
    print(json.dumps(result, sort_keys=True))
    return 3 if result.get('status', '').startswith('pending') else 0


if __name__ == '__main__':
    raise SystemExit(main())
