#!/usr/bin/env python3
"""Offline, stateless contracts for native AOR. No transport or task store."""
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
    for stage, checks in STAGES:
        record = stages.get(stage, {})
        require(isinstance(record, dict) and isinstance(record.get('checks', {}), dict), 'E_RECORD')
        if not (record.get('aor_attestation_ref') and record.get('effect_id')
                and record.get('observed_at') and record.get('artifact_sha256')):
            return {'status': 'pending', 'stage': stage, 'missing': ['bound_aor_evidence']}
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


def squad_changes(before, inbound, host_squads, host_mode):
    """Input MUST be a fresh complete GET /internal-squads, all pages unwrapped by AOR."""
    ids = [s['uuid'] for s in before]
    require(bool(ids) and len(ids) == len(set(ids)), 'E_SQUADS_EMPTY_OR_DUPLICATE')
    require(host_mode == 'ALLOW_ONLY' and set(host_squads) == set(ids)
            and len(host_squads) == len(ids), 'E_HOST_SQUADS')
    return [{'uuid': s['uuid'], 'inbounds': sorted(set(s['inbounds']) | {inbound})}
            for s in before]  # users deliberately excluded from PATCH


def verify_squads(before, after, inbound):
    require({s['uuid'] for s in before} == {s['uuid'] for s in after}, 'E_SQUAD_RACE')
    require(len(after) == len(before), 'E_SQUAD_DUPLICATE')
    lookup = {s['uuid']: s for s in after}
    for s in before:
        a = lookup[s['uuid']]
        require(set(a['inbounds']) == set(s['inbounds']) | {inbound}, 'E_INBOUNDS')
        require(a.get('users') == s.get('users'), 'E_USERS')


def origin(inventory, cloudflare, observed):
    addresses = [str(ipaddress.ip_address(x)) for x in (inventory, cloudflare, observed)]
    require(len(set(addresses)) == 1, 'E_ORIGIN_MISMATCH')
    return addresses[0]


def recovery(snapshot, output, members, databases):
    """Archive a provider-consistent READ-ONLY snapshot, never the live filesystem.

    AOR supplies verified snapshot paths and complete dependency closure. Root-only
    output contains PII/keys; CLI returns only checksum. No network or service effects.
    """
    require(os.geteuid() == 0, 'E_ROOT')
    snapshot = Path(snapshot).resolve(strict=True)
    require(bool(os.statvfs(snapshot).f_flag & os.ST_RDONLY), 'E_SNAPSHOT_NOT_READONLY')
    output = Path(output)
    require(output.parent.stat().st_uid == 0 and
            stat.S_IMODE(output.parent.stat().st_mode) == 0o700, 'E_PRIVATE_DIRECTORY')
    require(members and databases, 'E_EMPTY_RECOVERY')
    paths = []
    for name in members:
        p = Path(name)
        require(not p.is_absolute() and '..' not in p.parts, 'E_PATH')
        src = snapshot / p
        require(src.exists() and not src.is_symlink(), 'E_MISSING_OR_SYMLINK')
        require(src.resolve().is_relative_to(snapshot), 'E_PATH')
        paths.append((src, name))
    for name in databases:
        require(name in members, 'E_DB_NOT_ARCHIVED')
        db = snapshot / name
        with sqlite3.connect(db.as_uri() + '?mode=ro&immutable=1', uri=True) as connection:
            # Immutable SQLite ignores WAL; reject rather than silently lose committed data.
            require(not Path(str(db) + '-wal').exists(), 'E_SQLITE_WAL_NEEDS_CONSOLIDATED_SNAPSHOT')
            require(connection.execute('PRAGMA integrity_check').fetchall() == [('ok',)], 'E_SQLITE')
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'wb') as stream:
            with tarfile.open(fileobj=stream, mode='w:gz', dereference=False) as archive:
                for src, name in paths:
                    archive.add(src, arcname=name)
        # Read every member, including gzip CRC, without extracting untrusted links.
        with tarfile.open(output, 'r:gz') as archive:
            for member in archive:
                if member.isfile():
                    with archive.extractfile(member) as stream:
                        while stream.read(1024 * 1024):
                            pass
        digest = hashlib.sha256()
        with output.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        return digest.hexdigest()
    except BaseException:
        output.unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('evidence', type=Path)
    parser.add_argument('--task', required=True)
    parser.add_argument('--release', required=True)
    parser.add_argument('--operation', required=True)
    args = parser.parse_args()
    try:
        result = continuation(json.loads(args.evidence.read_text()), args.task, args.release, args.operation)
    except (ValueError, KeyError, OSError):
        parser.exit(2, 'E_INVALID_EVIDENCE\n')
    print(json.dumps(result, sort_keys=True))
    return 0 if result['status'] == 'evidence_ready_for_aor_verification' else 3


if __name__ == '__main__':
    raise SystemExit(main())
