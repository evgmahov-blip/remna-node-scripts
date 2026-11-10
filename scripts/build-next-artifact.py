#!/usr/bin/env python3
"""Deterministic local packaging; no Git access, downloads or installer execution."""
import base64
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE_COMMIT = 'ee240a73db2481eb3d08d8806866a14d08a10ad6'

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'))

def build(output):
    lock = json.loads((ROOT / 'scripts/next-artifact-source-lock.json').read_text())
    if lock['source_commit'] != SOURCE_COMMIT:
        raise ValueError('source commit mismatch')
    files = {}
    for name, expected in lock['sha256'].items():
        data = (ROOT / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError('source hash mismatch: ' + name)
        files[name] = base64.b64encode(data).decode('ascii')
    vendor = {}
    with tarfile.open(fileobj=io.BytesIO(base64.b64decode(files['vendor/remna-next-source.tar.gz'])), mode='r:gz') as archive:
        for member in archive.getmembers():
            if member.isdir():
                continue
            if not member.isfile() or member.name in vendor:
                raise ValueError('invalid vendor member')
            vendor[member.name] = hashlib.sha256(archive.extractfile(member).read()).hexdigest()
    runtime = (ROOT / 'scripts/next-artifact-runtime.py').read_text()
    code = '\n'.join(f'{k} = {v!r}' for k, v in dict(
        SOURCE_COMMIT=SOURCE_COMMIT, MANIFEST=lock['sha256'],
        MANIFEST_SHA256=hashlib.sha256(canonical(lock).encode()).hexdigest(),
        VENDOR_MANIFEST=vendor, BLOCKERS=lock['blockers'],
        PAYLOAD=base64.b64encode(canonical(files).encode()).decode()).items()) + '\n' + runtime
    # Read embedded code through fd 3 to avoid argv size limits; fd 0 is secret input.
    artifact = ("#!/bin/sh\nset +x\nexec /usr/bin/python3 -I -B -c "
                "\"import os; exec(compile(os.fdopen(3).read(), '<next-preflight>', 'exec'))\" "
                "\"$@\" 3<<'REMNA_EMBEDDED_PYTHON'\n" + code +
                "\nREMNA_EMBEDDED_PYTHON\n")
    output.write_bytes(artifact.encode())
    output.chmod(0o700)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_name(output.name + '.sha256').write_text(digest + '  ' + output.name + '\n')
    output.with_name(output.name + '.manifest.json').write_text(canonical(lock) + '\n')
    print(canonical(dict(artifact_sha256=digest, source_commit=SOURCE_COMMIT, status='BUILT_PREFLIGHT_ONLY')))

if __name__ == '__main__':
    try:
        if len(sys.argv) != 2:
            raise ValueError('usage: build-next-artifact.py OUTPUT.sh')
        build(Path(sys.argv[1]))
    except (ValueError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)
