import importlib.util
import json
from pathlib import Path
import tempfile
import stat
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('health', Path(__file__).resolve().parents[2] / 'next-installer/node-health.py')
health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(health)


class HealthTests(unittest.TestCase):
    def test_profile_ignores_only_documented_fields(self):
        expected = {'inbounds': [{'protocol': 'vless', 'port': 443, 'tag': 'x', 'settings': {'clients': []}}]}
        actual = json.loads(json.dumps(expected))
        actual['inbounds'][0]['tag'] = 'runtime'
        actual['inbounds'][0]['settings']['clients'] = [{'id': 'SECRET'}]
        self.assertTrue(health.same_profile(expected, actual))
        actual['inbounds'][0]['port'] = 444
        self.assertFalse(health.same_profile(expected, actual))
        self.assertFalse(health.same_profile({'inbounds': []}, {'inbounds': []}))

    def report(self, runtime):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / '.transport').write_text('xhttp')
            (base / '.env').write_text('NODE_PORT=2222\nSECRET_KEY=DO_NOT_PRINT')
            (base / 'remnawave-profiles').mkdir()
            (base / 'remnawave-profiles/xhttp-reality.json').write_text(json.dumps({
                'inbounds': [{'protocol': 'vless', 'port': 443, 'settings': {'clients': []}}]}))
            def capture(*args):
                if '--dump-config-raw' in args:
                    return json.dumps(runtime)
                if 'inspect' in args:
                    return '{"Running":true}'
                if args[0] == 'ss':
                    return 'LISTEN'
                if 'tcp_congestion_control' in ' '.join(args):
                    return 'bbr'
                if 'default_qdisc' in ' '.join(args):
                    return 'fq'
                if 'sh' in args:
                    return '65536 65536'
                return ''
            original_stat = Path.stat
            def path_stat(path, *args, **kwargs):
                if str(path) == '/dev/shm/nginx.sock':
                    return SimpleNamespace(st_mode=stat.S_IFSOCK | 0o600)
                return original_stat(path, *args, **kwargs)
            with patch.object(health, 'capture', side_effect=capture), patch.object(Path, 'stat', path_stat):
                return health.check(base)

    def test_wait_for_panel_is_not_failure_or_success(self):
        report = self.report({'inbounds': []})
        self.assertEqual(report['result'], 'WAIT')
        self.assertNotIn('DO_NOT_PRINT', json.dumps(report))

    def test_drift_is_failure_without_secrets(self):
        report = self.report({'inbounds': [{'protocol': 'vless', 'port': 444,
                                           'settings': {'clients': [{'id': 'SECRET'}]}}]})
        self.assertEqual(report['result'], 'FAIL')
        self.assertNotIn('SECRET', json.dumps(report))

    def test_unavailable_commands_are_failures_not_tracebacks(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(health, 'capture', side_effect=ValueError('SECRET')):
            report = health.check(Path(directory))
        self.assertEqual(report['result'], 'FAIL')
        self.assertNotIn('SECRET', json.dumps(report))


if __name__ == '__main__':
    unittest.main()
