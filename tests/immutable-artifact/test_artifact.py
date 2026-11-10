import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.artifact = self.root / 'next.sh'
        self.build(self.artifact)

    def build(self, output, script=None):
        return subprocess.run(['python3', str(script or ROOT / 'scripts/build-next-artifact.py'), str(output)], capture_output=True, check=True)

    def run_artifact(self, secret=b'synthetic-secret-ONLY\n', args=('--dry-run',), extra=None, cwd=None):
        env = dict(os.environ, DOMAIN='node.example.com', EMAIL='ops@example.com')
        env.pop('SECRET_KEY', None)
        env.update(extra or {})
        result = subprocess.run([str(self.artifact), *args], input=secret, env=env, capture_output=True, cwd=cwd)
        self.assertNotIn(b'synthetic-secret-ONLY', result.stdout + result.stderr)
        self.assertEqual(result.stderr, b'')
        rows = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertTrue(all(row['writes'] is False for row in rows))
        return result.returncode, rows

    def test_reproducible_sha(self):
        other = self.root / 'other.sh'
        self.build(other)
        self.assertEqual(self.artifact.read_bytes(), other.read_bytes())
        expected = self.artifact.with_name('next.sh.sha256').read_text().split()[0]
        self.assertEqual(expected, hashlib.sha256(self.artifact.read_bytes()).hexdigest())
        subprocess.run(['sh', '-n', str(self.artifact)], check=True)

    def test_unpinned_dependencies_block_even_in_dry_run(self):
        code, rows = self.run_artifact()
        self.assertEqual(code, 3)
        self.assertEqual(rows[-1]['status'], 'BLOCKED_NOT_AVAILABLE')
        self.assertFalse(rows[-1]['ready'])
        self.assertIn('DOCKER_IMAGES', {d['id'] for d in rows[-1]['dependencies']})
        self.assertEqual([r['event'] for r in rows], ['started', 'sources_verified', 'inputs_validated', 'completed'])

    def test_launcher_ignores_import_and_path_hijacks(self):
        hostile = self.root / 'hostile'
        hostile.mkdir()
        for name in ('json.py', 'hashlib.py', 'sitecustomize.py'):
            (hostile / name).write_text("raise RuntimeError('IMPORT_HIJACK')\n")
        fake_python = hostile / 'python3'
        fake_python.write_text('#!/bin/sh\necho PATH_HIJACK >&2\nexit 99\n')
        fake_python.chmod(0o700)
        code, rows = self.run_artifact(cwd=hostile, extra={
            'PYTHONPATH': str(hostile), 'PYTHONHOME': str(hostile),
            'PYTHONUSERBASE': str(hostile), 'PATH': str(hostile),
        })
        self.assertEqual(code, 3)
        self.assertEqual(rows[-1]['status'], 'BLOCKED_NOT_AVAILABLE')

    def test_missing_secret(self):
        code, rows = self.run_artifact(b'')
        self.assertEqual(code, 2)
        self.assertEqual(rows[-1]['reasons'], ['MISSING_SECRET'])

    def test_invalid_inputs_and_env_secret(self):
        for extra in ({'DOMAIN': 'bad;command'}, {'DOMAIN': '1.2.3.4'}, {'DOMAIN': 'node.123'}, {'EMAIL': 'bad\nmail'}, {'SECRET_KEY': 'synthetic-secret-ONLY'}):
            self.assertEqual(self.run_artifact(extra=extra)[0], 2)
        self.assertEqual(self.run_artifact(args=('--install',))[0], 2)

    def test_no_apply_path(self):
        code, rows = self.run_artifact(args=())
        self.assertIn(code, (2, 3))
        self.assertIn(rows[-1]['status'], ('REJECTED', 'BLOCKED_NOT_AVAILABLE'))

    def test_wrong_source_and_vendor_rejected_at_build(self):
        fixture = self.root / 'fixture'
        fixture.mkdir()
        paths = json.loads((ROOT / 'scripts/next-artifact-source-lock.json').read_text())['sha256']
        for name in [*paths, 'scripts/build-next-artifact.py', 'scripts/next-artifact-runtime.py', 'scripts/next-artifact-source-lock.json']:
            dest = fixture / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, dest)
        for name in ('install.sh', 'vendor/remna-next-source.tar.gz'):
            path = fixture / name
            original = path.read_bytes()
            path.write_bytes(original + b'corrupt')
            with self.assertRaises(subprocess.CalledProcessError):
                self.build(self.root / 'bad.sh', fixture / 'scripts/build-next-artifact.py')
            path.write_bytes(original)

    def test_embedded_source_tamper_rejected(self):
        data = self.artifact.read_text()
        start = data.index("PAYLOAD = '") + len("PAYLOAD = '")
        data = data[:start] + ('A' if data[start] != 'A' else 'B') + data[start+1:]
        self.artifact.write_text(data)
        self.assertEqual(self.run_artifact()[0], 2)

if __name__ == '__main__':
    unittest.main()
