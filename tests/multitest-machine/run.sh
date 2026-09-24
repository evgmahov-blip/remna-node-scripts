#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TESTER="$ROOT/next-installer/server-multitest.sh"
FULL="$ROOT/full-clean-reinstall.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

bash -n "$TESTER"
bash -n "$FULL"

TESTER_LIB="$WORK/tester-lib.sh"
sed '$d' "$TESTER" >"$TESTER_LIB"
source "$TESTER_LIB"

D="$WORK/run"
mkdir -p "$D"
cat >"$D/summary.tsv" <<'TSV'
test	name	status	duration_sec	rc
1	IP Region	PASS	1	0
7	IPQuality	PASS	2	0
8	sysbench CPU	PASS	20	0
9	Network Bench — HTTPS 100MB	PASS	4	0
11	NextTrace Path MTU	PASS	2	0
13	AI Access	PASS	1	0
TSV
cat >"$D/meta.txt" <<'META'
host=test-node
utc_start=2026-09-24T12:00:00Z
kernel=Linux
tester=remnanode-next-server-multitest
META
printf 'CPU single-thread:\nevents per second: 1234.50\nCPU all-thread (4 threads):\nevents per second: 4321.00\n' >"$D/08-sysbench-cpu.log"
printf 'Average:    500.00 Mbit/s\n' >"$D/09-network-bench.log"
printf 'Path MTU: 1500\n' >"$D/11-nexttrace-mtu.log"
cat >"$D/07-ipquality.log" <<'IPQ'
ASN: AS123 Test
Region: DE / Frankfurt
Usage: hosting
Risk: 10
Proxy flags: proxy=false
Media: Netflix=YES
DNSBL: clean=10 marked=0 blacklisted=0
IPQ
cat >"$D/13-ai-access.log" <<'AI'
OpenAI      REACHABLE_AUTH       HTTP=401 IP=1.1.1.1 connect=0.01s tls=0.02s
Anthropic   REACHABLE_AUTH       HTTP=401 IP=1.1.1.2 connect=0.01s tls=0.02s
Gemini      REACHABLE_AUTH       HTTP=403 IP=1.1.1.3 connect=0.01s tls=0.02s
Mistral     REACHABLE_AUTH       HTTP=401 IP=1.1.1.4 connect=0.01s tls=0.02s
xAI/Grok    REACHABLE_AUTH       HTTP=401 IP=1.1.1.5 connect=0.01s tls=0.02s
Perplexity  REACHABLE_AUTH       HTTP=401 IP=1.1.1.6 connect=0.01s tls=0.02s
AI_SUMMARY: reachable=6 failed=0 total=6
AI

REPORT_ROOT="$D"
generate_json_report "$D" machine
python3 - "$D/result.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8"))
assert d["schema"] == "remnanode.multitest.v1"
assert d["execution_mode"] == "machine"
assert d["overall_status"] == "PASS"
assert d["metrics"]["network_mbps"] == 500.0
assert d["metrics"]["working_budget_mbps"] == 350.0
assert d["metrics"]["cpu_single_events_sec"] == 1234.5
assert d["metrics"]["cpu_all_events_sec"] == 4321.0
assert d["metrics"]["path_mtu"] == 1500
assert d["metrics"]["ipquality"]["dnsbl_blacklisted"] == 0
assert d["metrics"]["ai_access"]["reachable"] == 6
assert len(d["metrics"]["ai_access"]["providers"]) == 6
PY

MULTITEST_NO_INSTALL=1
APT_CALLED=0
apt_install(){ APT_CALLED=1; return 99; }
if need_cmd __ainoc_missing_test_cmd__ fake-package 2>/dev/null; then
  echo "need_cmd unexpectedly passed" >&2
  exit 1
fi
[[ "$APT_CALLED" == 0 ]]

FULL_LIB="$WORK/full-lib.sh"
sed '$d' "$FULL" >"$FULL_LIB"
source "$FULL_LIB"
APP_DIR="$WORK/node"
mkdir -p "$APP_DIR"
RELEASE_MARKER="$APP_DIR/.ainoc-release.json"
printf 'node.example.com\n' >"$APP_DIR/.node_domain"
REBUILD="$WORK/fake-rebuild.sh"
cat >"$REBUILD" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod 0700 "$REBUILD"
sync_next_sources(){ :; }
AINOC_RELEASE_SHA="0123456789abcdef0123456789abcdef01234567"
run_managed_update
STATUS="$(release_status)"
python3 - "$STATUS" <<'PY'
import json, sys
d=json.loads(sys.argv[1])
assert d["schema"] == "remnanode.release.v1"
assert d["installed"] is True
assert d["release_sha"] == "0123456789abcdef0123456789abcdef01234567"
assert d["method"] == "managed-rebuild"
PY
[[ "$(stat -c %a "$RELEASE_MARKER")" == 600 ]]

rm -f "$RELEASE_MARKER"
cat >"$REBUILD" <<'SH'
#!/usr/bin/env bash
exit 7
SH
chmod 0700 "$REBUILD"
if ( run_managed_update >/dev/null 2>&1 ); then
  echo "managed update unexpectedly passed failed rebuild" >&2
  exit 1
fi
[[ ! -e "$RELEASE_MARKER" ]]

echo "MULTITEST_MACHINE_TESTS=PASS"
