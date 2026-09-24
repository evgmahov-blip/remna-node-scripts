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
mkdir -p "$APP_DIR/remnawave-profiles" "$WORK/etc/telemt" "$WORK/etc/telemt-panel"
RELEASE_MARKER="$APP_DIR/.ainoc-release.json"
MANAGED_UPDATE_BACKUP_ROOT="$WORK/backups"
TELEMT_CONFIG_FILE="$WORK/etc/telemt/telemt.toml"
TELEMT_PANEL_CONFIG_FILE="$WORK/etc/telemt-panel/config.toml"
SELF="$WORK/remnanode-next.sh"
NEXT_DIR="$APP_DIR/next-installer"
PROTECTION="$APP_DIR/protection-manager.sh"
SECURITY_DIR="$APP_DIR/security"
mkdir -p "$NEXT_DIR" "$SECURITY_DIR"
printf '#!/usr/bin/env bash\n' >"$SELF"
printf '#!/usr/bin/env bash\n' >"$NEXT_DIR/server-multitest.sh"
printf '#!/usr/bin/env bash\n' >"$PROTECTION"
printf 'services: {}\n' >"$APP_DIR/docker-compose.yml"
printf 'NODE_PORT=2222\nSECRET_KEY=test-secret\nXTLS_API_PORT=61000\n' >"$APP_DIR/.env"
printf 'node.example.com\n' >"$APP_DIR/.node_domain"
printf '203.0.113.10\n' >"$APP_DIR/.panel_ip"
printf 'combined\n' >"$APP_DIR/.transport"
printf 'selfsteal\n' >"$APP_DIR/.camouflage_mode"
printf 'REALITY_PRIVATE_KEY=a\nREALITY_PUBLIC_KEY=b\nREALITY_SHORT_ID=c\n' >"$APP_DIR/reality.env"
printf 'node.example.com\n' >"$APP_DIR/.reality_sni"
printf '/dev/shm/nginx.sock\n' >"$APP_DIR/.reality_target"
printf '/api/stable/path.ts\n' >"$APP_DIR/.xhttp_path"
printf 'nginx-stable\n' >"$APP_DIR/nginx.conf"
printf '{"signature":"stable"}\n' >"$APP_DIR/xhttp-signature.json"
printf '{"profile":"stable"}\n' >"$APP_DIR/remnawave-profiles/xhttp-reality.json"
printf 'telemt=stable\n' >"$TELEMT_CONFIG_FILE"
printf 'panel=stable\n' >"$TELEMT_PANEL_CONFIG_FILE"

before="$(managed_identity_digest)"
backup="$(managed_update_backup)"
printf '/api/changed/path.ts\n' >"$APP_DIR/.xhttp_path"
printf 'REALITY_PRIVATE_KEY=changed\n' >"$APP_DIR/reality.env"
printf 'nginx-changed\n' >"$APP_DIR/nginx.conf"
printf '{"signature":"changed"}\n' >"$APP_DIR/xhttp-signature.json"
printf '{"profile":"new"}\n' >"$APP_DIR/remnawave-profiles/host-new.json"
printf 'telemt=changed\n' >"$TELEMT_CONFIG_FILE"
after="$(managed_identity_digest)"
[[ "$before" != "$after" ]]
managed_update_restore_identity "$backup"
[[ "$(managed_identity_digest)" == "$before" ]]
[[ "$(cat "$APP_DIR/.xhttp_path")" == '/api/stable/path.ts' ]]
grep -Fq 'REALITY_PRIVATE_KEY=a' "$APP_DIR/reality.env"
[[ "$(cat "$APP_DIR/nginx.conf")" == 'nginx-stable' ]]
grep -Fq '"signature":"stable"' "$APP_DIR/xhttp-signature.json"
[[ ! -e "$APP_DIR/remnawave-profiles/host-new.json" ]]
[[ "$(cat "$TELEMT_CONFIG_FILE")" == 'telemt=stable' ]]

managed_update_backup(){ mkdir -p "$WORK/backup"; printf '%s\n' "$WORK/backup"; }
managed_patch_node_image(){ :; }
managed_update_postcheck(){ :; }
managed_running_image_digest(){ printf '%s\n' "$NODE_IMAGE_DIGEST"; }
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
assert d["method"] == "in-place"
assert d["identity_ok"] is True
assert d["image_ok"] is True
assert len(d["identity_digest"]) == 64
PY
[[ "$(stat -c %a "$RELEASE_MARKER")" == 600 ]]

rm -f "$RELEASE_MARKER"
managed_update_rollback(){
  printf '/api/stable/path.ts\n' >"$APP_DIR/.xhttp_path"
  touch "$WORK/rollback.called"
  return 0
}
sync_next_sources(){ printf '/api/drifted/path.ts\n' >"$APP_DIR/.xhttp_path"; }
if ( run_managed_update >/dev/null 2>&1 ); then
  echo "managed update unexpectedly passed identity drift" >&2
  exit 1
fi
[[ ! -e "$RELEASE_MARKER" ]]
[[ -e "$WORK/rollback.called" ]]
[[ "$(cat "$APP_DIR/.xhttp_path")" == '/api/stable/path.ts' ]]

rm -f "$WORK/rollback.called"
sync_next_sources(){ return 9; }
if ( run_managed_update >/dev/null 2>&1 ); then
  echo "managed update unexpectedly passed source-sync failure" >&2
  exit 1
fi
[[ -e "$WORK/rollback.called" ]]
[[ ! -e "$RELEASE_MARKER" ]]

grep -Fq 'CONNECTION IDENTITY DRIFT' "$FULL"
! sed -n '/run_managed_update(){/,/^}/p' "$FULL" | grep -Fq '"$REBUILD" rebuild'

echo "MULTITEST_MACHINE_TESTS=PASS"
