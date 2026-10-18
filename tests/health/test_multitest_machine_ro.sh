#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
script="$root/next-installer/server-multitest.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for name in apt-get curl wget iperf3 sysbench fio; do
  cat > "$tmp/$name" <<'EOF'
#!/usr/bin/env bash
echo forbidden >> "${MULTITEST_TEST_SENTINEL}"
exit 99
EOF
  chmod 700 "$tmp/$name"
done
export MULTITEST_TEST_SENTINEL="$tmp/forbidden"
bash -n "$script"
PATH="$tmp:$PATH" bash "$script" machine > "$tmp/machine.json"
test ! -e "$tmp/forbidden"
python3 - "$tmp/machine.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['schema']=='remnanode.multitest.v1'
assert p['overall_status'] in ('PASS','FAIL','UNKNOWN')
assert p['counts']['total']==len(p['tests'])
assert sum(p['counts'][k] for k in ('pass','fail','skip'))==p['counts']['total']
assert p['duration_sec']>=0
assert all(t['status'] in ('PASS','FAIL','SKIP') for t in p['tests'])
assert isinstance(p['metrics'],dict)
print('machine read-only JSON contract OK')
PY

# Missing mandatory Docker / TCP probes must not return a green PASS.
for name in docker ss; do
  cat > "$tmp/$name" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod 700 "$tmp/$name"
done
PATH="$tmp:$PATH" bash "$script" machine > "$tmp/unknown.json"
python3 - "$tmp/unknown.json" <<'PYUNKNOWN'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['overall_status']=='UNKNOWN',p
print('unknown-on-missing-critical-probes OK')
PYUNKNOWN
