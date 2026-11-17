import importlib.util
from pathlib import Path
import unittest

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
        before = [{'uuid': 'a', 'inbounds': ['old'], 'users': ['u']},
                  {'uuid': 'b', 'inbounds': [], 'users': []}]
        changes = a.squad_changes(before, 'new', ['a', 'b'], 'ALLOW_ONLY')
        self.assertNotIn('users', changes[0])
        after = [dict(x, users=before[i]['users']) for i, x in enumerate(changes)]
        a.verify_squads(before, after, 'new')
        with self.assertRaisesRegex(ValueError, 'E_SQUAD_RACE'):
            a.verify_squads(before, after[:1], 'new')
        with self.assertRaisesRegex(ValueError, 'E_HOST_SQUADS'):
            a.squad_changes(before, 'new', ['a'], 'ALLOW_ONLY')
        after[0]['users'] = []
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
                                        'observed_at': 'now', 'artifact_sha256': 'b'*64,
                                        'checks': dict.fromkeys(checks, True)}
        self.assertEqual(run()['status'], 'evidence_ready_for_aor_verification')
        evidence['stages']['OWNER_GATE']['checks']['owner_production_approval'] = False
        self.assertEqual(run()['stage'], 'OWNER_GATE')
        evidence['operation_id'] = 'another'
        with self.assertRaisesRegex(ValueError, 'E_BINDING'):
            run()

    def test_live_backup_rejected(self):
        with self.assertRaises(ValueError):
            a.recovery('/', '/tmp/never-create-remna-test.tar.gz', ['etc'], ['etc'])


if __name__ == '__main__':
    unittest.main()
