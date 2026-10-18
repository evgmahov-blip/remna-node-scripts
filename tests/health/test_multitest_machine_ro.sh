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
