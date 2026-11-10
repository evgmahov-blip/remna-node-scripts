"""Embedded preflight only. Never import or execute the archived installer."""
import base64
import hashlib
import io
import json
import os
import re
import stat
import sys
import tarfile


def emit(event, status, **fields):
    print(json.dumps(dict(schema='remnanode.next.artifact.v1', event=event,
                         status=status, source_commit=SOURCE_COMMIT, **fields),
                     sort_keys=True), flush=True)


def stop(reason, code=2):
    emit('completed', 'REJECTED', reasons=[reason], writes=False)
    raise SystemExit(code)


emit('started', 'PREFLIGHT', writes=False)
args = sys.argv[1:]
if args not in ([], ['--dry-run']):
    stop('INVALID_ARGUMENTS')
dry = args == ['--dry-run']
try:
    files = json.loads(base64.b64decode(PAYLOAD, validate=True))
    if set(files) != set(MANIFEST):
        stop('SOURCE_MANIFEST_MISMATCH')
    decoded = {}
    for name, encoded in files.items():
        data = base64.b64decode(encoded, validate=True)
        if hashlib.sha256(data).hexdigest() != MANIFEST[name]:
            stop('SOURCE_HASH_MISMATCH')
        decoded[name] = data
    # Verify archive members in memory; never extract paths or execute sources.
    with tarfile.open(fileobj=io.BytesIO(decoded['vendor/remna-next-source.tar.gz']), mode='r:gz') as archive:
        members = [m for m in archive.getmembers() if not m.isdir()]
        if {m.name for m in members} != set(VENDOR_MANIFEST) or len(members) != len(VENDOR_MANIFEST):
            stop('VENDOR_MANIFEST_MISMATCH')
        for member in members:
            if not member.isfile() or hashlib.sha256(archive.extractfile(member).read()).hexdigest() != VENDOR_MANIFEST[member.name]:
                stop('VENDOR_HASH_MISMATCH')
except (ValueError, KeyError, OSError, tarfile.TarError):
    stop('INVALID_EMBEDDED_SOURCE')
emit('sources_verified', 'VERIFIED', manifest_sha256=MANIFEST_SHA256, writes=False)
domain = os.environ.get('DOMAIN', '')
email = os.environ.get('EMAIL', '')
if len(domain) > 253 or '.' not in domain or not all(re.fullmatch(r'[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?', p) for p in domain.split('.')):
    stop('INVALID_DOMAIN')
if len(email) > 254 or not re.fullmatch(r'[A-Za-z0-9.!#$%&\x27*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}', email):
    stop('INVALID_EMAIL')
# No env bridge is needed for a preflight; accept only the protected stdin contract.
if 'SECRET_KEY' in os.environ:
    stop('SECRET_ENV_FORBIDDEN')
if not dry and os.geteuid() != 0:
    stop('ROOT_REQUIRED')
fd = os.fstat(0)
if os.isatty(0) or not (stat.S_ISFIFO(fd.st_mode) or (stat.S_ISREG(fd.st_mode) and fd.st_uid == os.geteuid() and fd.st_mode & 0o077 == 0)):
    stop('PROTECTED_STDIN_REQUIRED')
secret = sys.stdin.buffer.read(4098)
if not secret:
    stop('MISSING_SECRET')
if len(secret) > 4097 or not re.fullmatch(rb'[^\x00-\x20\x7f]{1,4096}\n?', secret):
    stop('INVALID_SECRET')
del secret
emit('inputs_validated', 'VALIDATED', dry_run=dry, writes=False)
emit('completed', 'BLOCKED_NOT_AVAILABLE', dry_run=dry, writes=False,
     dependencies=BLOCKERS, ready=False)
raise SystemExit(3)
