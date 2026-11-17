import importlib.util
from pathlib import Path
import unittest
import tempfile
import sqlite3
import os
import json
import subprocess
import sys
from unittest.mock import patch
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('adapter', Path(__file__).resolve().parents[2] / 'next-installer/aor_onboarding.py')
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)


class Safety(unittest.TestCase):
    def test_unverified_dns_is_not_origin(self):
        with self.assertRaisesRegex(ValueError, 'E_ORIGIN'):
            a.origin('192.0.2.1', '192.0.2.2', '192.0.2.2')

    def test_no_duplicate_or_drift_creation(self):
        self.assertEqual(a.reconcile([], {'name': 'SWE-NEXT'})['action'], 'create')
        self.assertEqual(a.reconcile([{'uuid': '1', 'name': 'SWE-NEXT'}], {'name': 'SWE-NEXT'})['action'], 'reuse')
        for old in ([{'name': 'other'}], [{}, {}]):
            with self.assertRaises(ValueError):
                a.reconcile(old, {'name': 'SWE-NEXT'})

    def test_every_squad_and_users_preserved(self):
        before = [{'uuid': 'a', 'inbounds': ['old'], 'info': {'membersCount': 1}},
                  {'uuid': 'b', 'inbounds': [], 'info': {'membersCount': 0}}]
        changes = a.squad_changes(before, 'new', ['a', 'b'], 'ALLOW_ONLY')
        self.assertNotIn('users', changes[0])
        after = [dict(x, info=before[i]['info']) for i, x in enumerate(changes)]
        a.verify_squads(before, after, 'new')
        with self.assertRaisesRegex(ValueError, 'E_SQUAD_RACE'):
            a.verify_squads(before, after[:1], 'new')
        with self.assertRaisesRegex(ValueError, 'E_HOST_SQUADS'):
            a.squad_changes(before, 'new', ['a'], 'ALLOW_ONLY')
        after[0]['info'] = {'membersCount': 0}
        with self.assertRaisesRegex(ValueError, 'E_USERS'):
            a.verify_squads(before, after, 'new')

    def test_stage_order_and_binding(self):
        evidence = {'schema': 'remna.aor-evidence.v1', 'task_id': 't', 'release': 'a'*40,
                    'operation_id': 'op', 'stages': {}}
        run = lambda: a.continuation(evidence, 't', 'a'*40, 'op')
        self.assertEqual(run()['stage'], 'PRECHECK')
        for stage, checks in a.STAGES:
            self.assertEqual(run()['stage'], stage)
            evidence['stages'][stage] = {'aor_attestation_ref': 'ref', 'effect_id': stage,
                                        'observed_at': '2026-11-17T12:00:00Z', 'artifact_sha256': 'b'*64,
                                        'checks': dict.fromkeys(checks, True)}
        self.assertEqual(run()['status'], 'evidence_ready_for_aor_verification')
        evidence['stages']['OWNER_GATE']['checks']['owner_production_approval'] = False
        self.assertEqual(run()['stage'], 'OWNER_GATE')
        evidence['operation_id'] = 'another'
        with self.assertRaisesRegex(ValueError, 'E_BINDING'):
            run()

    def test_api_objects_and_missing_counts(self):
        before = [{'uuid': 's', 'inbounds': [{'uuid': 'old', 'tag': 'old'}],
                   'info': {'membersCount': 8}}]
        after = [{'uuid': 's', 'inbounds': [{'uuid': 'old'}, {'uuid': 'new'}],
                  'info': {'membersCount': 8}}]
        a.verify_squads(before, after, 'new')
        del after[0]['info']
        with self.assertRaisesRegex(ValueError, 'E_MEMBERS_COUNT'):
            a.verify_squads(before, after, 'new')

    def test_recovery_positive_and_rejections(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            root.chmod(0o700)
            snapshot = root / 'snapshot'
            snapshot.mkdir()
            config = snapshot / 'etc' / 'x-ui'
            config.mkdir(parents=True)
            db = config / 'x-ui.db'
            with sqlite3.connect(db) as conn:
                conn.execute('CREATE TABLE inbounds (settings TEXT)')
                conn.execute('INSERT INTO inbounds VALUES (?)', ('{"clients": []}',))
            coverage = {k: {'paths': ['etc/x-ui']} for k in a.RECOVERY_CATEGORIES}
            output = root / 'bundle.tar.gz'
            with patch.object(a, 'owner_uid', return_value=0), patch.object(a.os, 'geteuid', return_value=0), patch.object(a.os, 'statvfs', return_value=SimpleNamespace(f_flag=os.ST_RDONLY)):
                checksum = a.recovery(snapshot, output, ['etc/x-ui'], ['etc/x-ui/x-ui.db'], coverage)
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)
                self.assertEqual(a.digest_file(output), checksum)
                result = a.restore_test(output, checksum)
                self.assertTrue(result['file_restore_verified'])
                self.assertFalse(result['runtime_restore_verified'])
                with self.assertRaisesRegex(ValueError, 'E_CHECKSUM'):
                    a.restore_test(output, '0'*64)
                for suffix, code in [('-wal', 'E_SQLITE_WAL'), ('-journal', 'E_SQLITE_JOURNAL')]:
                    sidecar = Path(str(db) + suffix)
                    sidecar.touch()
                    with self.assertRaisesRegex(ValueError, code):
                        a.recovery(snapshot, root / 'bad.tar.gz', ['etc/x-ui'], ['etc/x-ui/x-ui.db'], coverage)
                    sidecar.unlink()
                (config / 'link').symlink_to(db)
                with self.assertRaisesRegex(ValueError, 'E_SPECIAL_FILE'):
                    a.recovery(snapshot, root / 'bad.tar.gz', ['etc/x-ui'], ['etc/x-ui/x-ui.db'], coverage)
                (config / 'link').unlink()
                with self.assertRaisesRegex(ValueError, 'E_PATH'):
                    a.recovery(snapshot, root / 'bad.tar.gz', ['../escape'], ['etc/x-ui/x-ui.db'], coverage)
                db.write_bytes(b'not sqlite')
                with self.assertRaises(sqlite3.DatabaseError):
                    a.recovery(snapshot, root / 'bad.tar.gz', ['etc/x-ui'], ['etc/x-ui/x-ui.db'], coverage)
            with patch.object(a, 'owner_uid', return_value=0), patch.object(a.os, 'geteuid', return_value=0), patch.object(a.os, 'statvfs', return_value=SimpleNamespace(f_flag=0)):
                with self.assertRaisesRegex(ValueError, 'E_SNAPSHOT_NOT_READONLY'):
                    a.recovery(snapshot, root / 'bad.tar.gz', ['etc/x-ui'], ['etc/x-ui/x-ui.db'], coverage)

    def test_preflight_private_counts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            root.chmod(0o700)
            db = root / 'x-ui.db'
            with sqlite3.connect(db) as conn:
                conn.execute('CREATE TABLE inbounds (settings TEXT)')
                conn.execute('INSERT INTO inbounds VALUES (?)', ('{"clients":[{"email":"PRIVATE","enable":true}]}',))
            output = root / 'precheck.json'
            with patch.object(a, 'owner_uid', return_value=0), patch.object(a.os, 'geteuid', return_value=0):
                result = a.preflight(db, output, runner=lambda argv: 'x-ui.service loaded active running' if argv[0] == 'systemctl' else '')
            self.assertEqual(result['clients_count'], 1)
            self.assertEqual(result['topology_count'], 1)
            self.assertNotIn('PRIVATE', output.read_text())
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_evidence_formats_and_unique_effects(self):
        evidence = {'schema': 'remna.aor-evidence.v1', 'task_id': 't', 'release': 'a'*40,
                    'operation_id': 'op', 'stages': {}}
        for stage, checks in a.STAGES[:2]:
            evidence['stages'][stage] = {'aor_attestation_ref': 'ref', 'effect_id': stage,
                'observed_at': '2026-11-17T12:00:00Z', 'artifact_sha256': 'b'*64,
                'checks': dict.fromkeys(checks, True)}
        run = lambda: a.continuation(evidence, 't', 'a'*40, 'op')
        record = evidence['stages']['PRECHECK']
        record['artifact_sha256'] = 'bad'
        with self.assertRaisesRegex(ValueError, 'E_DIGEST'):
            run()
        record['artifact_sha256'] = 'b'*64
        record['observed_at'] = '2026-11-17'
        with self.assertRaisesRegex(ValueError, 'E_TIMESTAMP'):
            run()
        record['observed_at'] = '2026-11-17T12:00:00Z'
        evidence['stages']['BACKUP_RESTORE_PROOF']['effect_id'] = 'PRECHECK'
        with self.assertRaisesRegex(ValueError, 'E_EFFECT_DUPLICATE'):
            run()

    def test_private_directory_modes_and_owner(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with patch.object(a, 'owner_uid', return_value=0):
                root.chmod(0o755)
                with self.assertRaisesRegex(ValueError, 'E_PRIVATE_DIRECTORY'):
                    a.private_parent(root / 'out')
                root.chmod(0o700)
                a.private_parent(root / 'out')
            with patch.object(a, 'owner_uid', return_value=1000):
                with self.assertRaisesRegex(ValueError, 'E_PRIVATE_DIRECTORY'):
                    a.private_parent(root / 'out')

    def test_cli_squad_output_and_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            before = [{'uuid': 's', 'inbounds': [], 'info': {'membersCount': 1}}]
            after = [{'uuid': 's', 'inbounds': [{'uuid': 'new'}], 'info': {'membersCount': 1}}]
            for name, data in [('before', before), ('after', after),
                               ('host', {'mode': 'ALLOW_ONLY', 'internalSquads': ['s']})]:
                (root / name).write_text(json.dumps(data))
            command = [sys.executable, str(Path(a.__file__)), 'verify-squads',
                       '--before', str(root / 'before'), '--after', str(root / 'after'),
                       '--host', str(root / 'host'), '--inbound-uuid', 'new']
            result = subprocess.run(command, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['squads_count'], 1)
            (root / 'after').write_text('[{"uuid":"SECRET"}]')
            result = subprocess.run(command, text=True, capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn('SECRET', result.stdout + result.stderr)

    def test_live_backup_rejected(self):
        with self.assertRaises(ValueError):
            a.recovery('/', '/tmp/never-create-remna-test.tar.gz', ['etc'], ['etc'])


if __name__ == '__main__':
    unittest.main()
