#!/usr/bin/env bash
# Offline RemnaNode Security tests. They never touch the host firewall.
set -Eeuo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CLI=$ROOT/protection-manager.sh
PY=$ROOT/security/remna_sec.py
PASS=0

export REMNA_SECURITY_SIM=1
export REMNA_SECURITY_FORBID_LIVE=1
unset REMNA_SECURITY_SOURCE_TSPU REMNA_SECURITY_SOURCE_GOV REMNA_SECURITY_SOURCE_SCANNERS REMNA_SECURITY_SOURCE_GEO REMNA_SECURITY_CURL_BIN REMNA_SIM_FAIL_SWAP || true

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); printf 'ok %s\n' "$*"; }

begin() {
  local profile=${1:-docker}
  WORK=$(mktemp -d)
  export REMNA_SECURITY_BASE=$WORK/base
  mkdir -p "$REMNA_SECURITY_BASE/data"
  python3 "$PY" sim-seed --base "$REMNA_SECURITY_BASE" --profile "$profile"
  cat > "$REMNA_SECURITY_BASE/settings.conf" <<'EOF'
PANEL_IP=203.0.113.10
ENABLE_TSPU=1
ENABLE_GOV=1
ENABLE_GEOIP=0
ENABLE_SCANNERS=0
FILTER_PORTS=443
GEO_COUNTRIES=
SCANNER_URL=
BACKEND=iptables
LOG_DROPS=0
EOF
  chmod 0600 "$REMNA_SECURITY_BASE/settings.conf"
  unset REMNA_SECURITY_SOURCE_TSPU REMNA_SECURITY_SOURCE_GOV REMNA_SECURITY_SOURCE_SCANNERS REMNA_SECURITY_SOURCE_GEO REMNA_SECURITY_CURL_BIN REMNA_SIM_FAIL_SWAP || true
}

nets() {
  local n=$1 start=${2:-1} i
  for ((i = 0; i < n; i++)); do
    printf '10.%s.%s.0/24\n' $(( (start + i) / 256 )) $(( (start + i) % 256 ))
  done
}

write_pair() {
  local dir=$1 count=$2
  mkdir -p "$dir"
  nets "$count" 1 > "$dir/tspu.txt"
  {
    echo 'create gov hash:net family inet hashsize 1024 maxelem 65536'
    nets "$count" 400 | awk '{print "add gov "$1}'
  } > "$dir/gov.txt"
  export REMNA_SECURITY_SOURCE_TSPU=file://$dir/tspu.txt
  export REMNA_SECURITY_SOURCE_GOV=file://$dir/gov.txt
}

json_py() {
  python3 -c 'import json,sys; json.load(sys.stdin); print("json-ok")'
}

require_json() {
  local schema=$2
  DOC=$1 SCHEMA=$schema python3 - <<'PY'
import json, os, sys
doc = json.loads(os.environ["DOC"])
schema = os.environ["SCHEMA"]
if doc.get("schema") != schema:
    sys.exit(f"schema {doc.get('schema')} != {schema}")
need = {
    "remna-security.status.v1": ["ok", "backend", "backend_implementation", "panel_ip", "node_api_2222", "filter_ports", "ipv6", "sources", "active_source_count", "last_update", "counters", "recent_events", "ruleset_health"],
    "remna-security.preflight.v1": ["ok", "blockers", "warnings", "detected_backend", "configured_backend", "nft_activation", "docker_present", "ufw_active", "owns_only", "ipv6_dynamic_lists"],
    "remna-security.update.v1": ["ok", "sources", "error", "changed"],
    "remna-security.selftest.v1": ["ok", "steps", "node_api_2222", "ipv6_dynamic_lists"],
}[schema]
missing = [k for k in need if k not in doc]
if missing:
    sys.exit("missing " + ",".join(missing))
if schema == "remna-security.status.v1" and doc["ipv6"]["dynamic_lists"]:
    sys.exit("dynamic ipv6 must be false")
if schema in {"remna-security.preflight.v1", "remna-security.selftest.v1"} and doc["ipv6_dynamic_lists"]:
    sys.exit("dynamic ipv6 must be false")
PY
}

echo "compile"
python3 -m py_compile "$PY"
bash -n "$CLI"
bash -n "$ROOT/security/remna-security.sh"
ok compile

echo "blob matches git"
begin docker
printf 'hello\n' > "$WORK/hello.txt"
got=$(python3 "$PY" blob --file "$WORK/hello.txt")
if command -v git >/dev/null 2>&1; then
  exp=$(git hash-object "$WORK/hello.txt")
  [ "$got" = "$exp" ] || fail "blob $got != $exp"
fi
[ "${#got}" -eq 40 ] || fail blob
ok blob

echo "direct feed rejects"
feed() {
  local name=$1 body=$2 reason=$3
  printf '%s' "$body" > "$WORK/$name.in"
  set +e
  python3 "$PY" validate --raw "$WORK/$name.in" --mode plain --family ipv4 --panel 203.0.113.10 --min-absolute 1 --print-json > "$WORK/$name.out"
  set -e
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["reason"]==sys.argv[2] and d["ok"] is False else 1)' "$WORK/$name.out" "$reason"
}
# reuse last WORK from begin
feed html '<html><title>err</title></html>' html
feed empty '' empty
feed bad $'10.1.0.0/24\n999.1.1.1/99\n' malformed
feed zero $'10.1.0.0/24\n0.0.0.0/0\n' broad
feed wide $'1.0.0.0/7\n' broad
feed v6 $'2001:db8::/32\n' family
ok feed-rejects

echo "gov parser and panel/whitelist collision"
{
  echo 'create gov hash:net family inet hashsize 1024 maxelem 65536'
  echo 'add gov 203.0.113.0/24'
  echo 'add gov 198.51.100.0/24'
  echo 'add gov 192.0.2.0/24'
} > "$WORK/gov.in"
printf '198.51.100.10\n' > "$WORK/allow.txt"
python3 "$PY" validate --raw "$WORK/gov.in" --mode gov --family ipv4 --panel 203.0.113.10 --allow "$WORK/allow.txt" --min-absolute 1 --print-json --show-entries > "$WORK/gov.out"
python3 - <<PY
import json
d=json.load(open("$WORK/gov.out"))
assert d["ok"] is True, d
assert d["panel_collisions"] == 1
assert d["whitelist_collisions"] == 1
assert d["accepted"] == 1
PY
printf '203.0.113.10/32\n' > "$WORK/only-panel.txt"
set +e
python3 "$PY" validate --raw "$WORK/only-panel.txt" --mode plain --family ipv4 --panel 203.0.113.10 --min-absolute 1 --print-json > "$WORK/only.out"
set -e
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["reason"]=="whitelist_or_panel_removed_all"' "$WORK/only.out"
ok collisions

echo "anomaly"
nets 60 1 > "$WORK/prev.txt"
nets 400 1 > "$WORK/huge.txt"
nets 5 1 > "$WORK/tiny.txt"
nets 70 1 > "$WORK/good.txt"
set +e
python3 "$PY" validate --raw "$WORK/huge.txt" --mode plain --family ipv4 --previous "$WORK/prev.txt" --panel 203.0.113.10 --min-absolute 1 --print-json > "$WORK/huge.out"
python3 "$PY" validate --raw "$WORK/tiny.txt" --mode plain --family ipv4 --previous "$WORK/prev.txt" --panel 203.0.113.10 --min-absolute 1 --print-json > "$WORK/tiny.out"
set -e
python3 "$PY" validate --raw "$WORK/good.txt" --mode plain --family ipv4 --previous "$WORK/prev.txt" --panel 203.0.113.10 --min-absolute 1 --print-json > "$WORK/good.out"
python3 - <<PY
import json
assert json.load(open("$WORK/huge.out"))["reason"] == "anomaly_huge"
assert json.load(open("$WORK/tiny.out"))["reason"] == "anomaly_tiny"
assert json.load(open("$WORK/good.out"))["ok"] is True
PY
ok anomaly

echo "good update, duplicate apply, json"
begin docker
SRC=$WORK/src
write_pair "$SRC" 12
doc=$(bash "$CLI" update --json)
require_json "$doc" remna-security.update.v1
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["ok"] is True, d' "$doc"
hash1=$(bash "$CLI" status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["ruleset_hash"])')
bash "$CLI" apply >/dev/null
hash2=$(bash "$CLI" status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["ruleset_hash"])')
[ "$hash1" = "$hash2" ] || fail "ruleset hash changed on duplicate apply"
jumps=$(python3 "$PY" audit --base "$REMNA_SECURITY_BASE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["guard_jumps"])')
[ "$jumps" = 1 ] || fail "jumps=$jumps"
python3 - <<PY
import json
state=json.load(open("$REMNA_SECURITY_BASE/sim/state.json"))
rules="\\n".join(state["chains"]["REMNA_GUARD"])
assert "-p udp" not in rules
assert "2222" in rules
assert "-j RETURN" in rules
assert "-p tcp" in rules
assert "203.0.113.10" in rules
text="\\n".join(state["last_commands"])
for bad in ("-F INPUT", "-F DOCKER", "ufw reset", "ufw --force reset", "nft flush ruleset"):
    assert bad not in text, bad
assert state["docker_chains"] == ["DOCKER", "DOCKER-USER"]
assert any(r.endswith("-j DOCKER-USER") for r in state["input"])
PY
doc=$(bash "$CLI" status --json)
require_json "$doc" remna-security.status.v1
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["node_api_2222"]=="protected"; assert d["sources"]["tspu"]["mode"]=="pinned"; assert d["ipv6"]["dynamic_lists"] is False' "$doc"
human=$(bash "$CLI" status)
printf '%s\n' "$human" | grep -q 'TCP/2222' || fail human-status
ok good-update

echo "download, html, empty, integrity keep lkg"
begin docker
printf '192.0.2.0/24\n' > "$REMNA_SECURITY_BASE/data/tspu.txt"
printf '198.51.100.0/24\n' > "$REMNA_SECURITY_BASE/data/gov.txt"
cp -a "$REMNA_SECURITY_BASE/data/tspu.txt" "$WORK/tspu.before"
cat > "$WORK/curlfail" <<'EOF'
#!/bin/sh
exit 22
EOF
chmod +x "$WORK/curlfail"
export REMNA_SECURITY_CURL_BIN=$WORK/curlfail
set +e
bash "$CLI" update --json > "$WORK/upd.json"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "download failure should fail"
cmp -s "$WORK/tspu.before" "$REMNA_SECURITY_BASE/data/tspu.txt" || fail "lkg replaced after download failure"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["ok"] is False; assert any(s["error"]=="download" for s in d["sources"])' "$WORK/upd.json"
cat > "$WORK/curlhtml" <<'EOF'
#!/bin/sh
printf '<html><body>gateway</body></html>\n' > "$2"
EOF
chmod +x "$WORK/curlhtml"
export REMNA_SECURITY_CURL_BIN=$WORK/curlhtml
set +e
bash "$CLI" update --json > "$WORK/html.json"
set -e
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert any(s["error"]=="html" for s in d["sources"]), d' "$WORK/html.json"
cmp -s "$WORK/tspu.before" "$REMNA_SECURITY_BASE/data/tspu.txt" || fail "html replaced lkg"
cat > "$WORK/curlempty" <<'EOF'
#!/bin/sh
: > "$2"
EOF
chmod +x "$WORK/curlempty"
export REMNA_SECURITY_CURL_BIN=$WORK/curlempty
set +e
bash "$CLI" update --json > "$WORK/empty.json"
set -e
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert any(s["error"]=="empty" for s in d["sources"]), d' "$WORK/empty.json"
cmp -s "$WORK/tspu.before" "$REMNA_SECURITY_BASE/data/tspu.txt" || fail "empty replaced lkg"
cat > "$WORK/curlgarbage" <<'EOF'
#!/bin/sh
printf 'this-is-not-the-pinned-snapshot\n' > "$2"
EOF
chmod +x "$WORK/curlgarbage"
export REMNA_SECURITY_CURL_BIN=$WORK/curlgarbage
set +e
bash "$CLI" update --json > "$WORK/pin.json"
set -e
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert any(s["error"]=="integrity" for s in d["sources"]), d' "$WORK/pin.json"
cmp -s "$WORK/tspu.before" "$REMNA_SECURITY_BASE/data/tspu.txt" || fail "integrity replaced lkg"
ok failure-keeps-lkg

echo "malformed, broad, family, anomaly through updater"
begin docker
SRC=$WORK/src
write_pair "$SRC" 12
bash "$CLI" update --json >/dev/null
cp "$REMNA_SECURITY_BASE/data/tspu.txt" "$WORK/tspu.good"
printf '10.9.9.0/24\nnot-a-cidr\n' > "$SRC/tspu.txt"
set +e
bash "$CLI" update --json > "$WORK/bad.json"
set -e
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert any(s["id"]=="tspu" and s["error"]=="malformed" for s in d["sources"]), d' "$WORK/bad.json"
cmp -s "$WORK/tspu.good" "$REMNA_SECURITY_BASE/data/tspu.txt" || fail malformed-replaced
printf '10.9.9.0/24\n0.0.0.0/0\n' > "$SRC/tspu.txt"
set +e
bash "$CLI" update --json > "$WORK/zero.json"
set -e
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert any(s["error"]=="broad" for s in d["sources"]), d' "$WORK/zero.json"
cmp -s "$WORK/tspu.good" "$REMNA_SECURITY_BASE/data/tspu.txt" || fail broad-replaced
printf '1.0.0.0/7\n' > "$SRC/tspu.txt"
set +e
bash "$CLI" update --json > "$WORK/pfx.json"
set -e
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert any(s["error"]=="broad" for s in d["sources"]), d' "$WORK/pfx.json"
printf '2001:db8::/48\n' > "$SRC/tspu.txt"
set +e
bash "$CLI" update --json > "$WORK/fam.json"
set -e
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert any(s["error"]=="family" for s in d["sources"]), d' "$WORK/fam.json"
nets 80 1 > "$SRC/tspu.txt"
bash "$CLI" update --json >/dev/null || fail "expected in-range growth to pass"
cp "$REMNA_SECURITY_BASE/data/tspu.txt" "$WORK/tspu.base"
nets 500 1 > "$SRC/tspu.txt"
set +e
bash "$CLI" update --json > "$WORK/hugeu.json"
set -e
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert any(s["error"]=="anomaly_huge" for s in d["sources"]), d' "$WORK/hugeu.json"
cmp -s "$WORK/tspu.base" "$REMNA_SECURITY_BASE/data/tspu.txt" || fail huge-replaced
nets 3 1 > "$SRC/tspu.txt"
set +e
bash "$CLI" update --json > "$WORK/tinyu.json"
set -e
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert any(s["error"]=="anomaly_tiny" for s in d["sources"]), d' "$WORK/tinyu.json"
cmp -s "$WORK/tspu.base" "$REMNA_SECURITY_BASE/data/tspu.txt" || fail tiny-replaced
ok updater-rejects

echo "atomic swap failure"
begin docker
SRC=$WORK/src
write_pair "$SRC" 12
bash "$CLI" update >/dev/null
cp "$REMNA_SECURITY_BASE/data/tspu.txt" "$WORK/before-swap.txt"
python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["sets"]["REMNA_TSPU"]))' "$REMNA_SECURITY_BASE/sim/state.json" > "$WORK/count.before"
nets 20 1 > "$SRC/tspu.txt"
export REMNA_SIM_FAIL_SWAP=1
set +e
bash "$CLI" update >/dev/null
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "atomic failure returned 0"
unset REMNA_SIM_FAIL_SWAP
cmp -s "$WORK/before-swap.txt" "$REMNA_SECURITY_BASE/data/tspu.txt" || fail "atomic failure promoted feed"
python3 - <<PY
import json
state=json.load(open("$REMNA_SECURITY_BASE/sim/state.json"))
before=int(open("$WORK/count.before").read().strip())
assert len(state["sets"]["REMNA_TSPU"]) == before
PY
ok atomic-failure

echo "whitelist and panel in external list"
begin docker
SRC=$WORK/src
write_pair "$SRC" 4
printf '198.51.100.10\n' > "$REMNA_SECURITY_BASE/data/allow.txt"
{
  echo '10.1.0.0/24'
  echo '203.0.113.0/24'
  echo '198.51.100.0/24'
} > "$SRC/tspu.txt"
doc=$(bash "$CLI" update --json)
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); tspu=[s for s in d["sources"] if s["id"]=="tspu"][0]; assert tspu["ok"] and tspu["panel_collisions"]>=1 and tspu["whitelist_collisions"]>=1, d' "$doc"
grep -q '203.0.113.0/24' "$REMNA_SECURITY_BASE/data/tspu.txt" && fail "panel network installed" || true
grep -q '198.51.100.0/24' "$REMNA_SECURITY_BASE/data/tspu.txt" && fail "allow network installed" || true
grep -q '10.1.0.0/24' "$REMNA_SECURITY_BASE/data/tspu.txt" || fail "good network missing"
set +e
bash "$CLI" deny-add 203.0.113.10 >/dev/null
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "deny of panel accepted"
set +e
bash "$CLI" deny-add 0.0.0.0/0 >/dev/null
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "default route deny accepted"
bash "$CLI" allow-add 192.0.2.10 >/dev/null
bash "$CLI" allow-add 192.0.2.10 >/dev/null
[ "$(grep -c . "$REMNA_SECURITY_BASE/data/allow.txt")" -eq 2 ] || fail "allow file not idempotent"
ok whitelist-panel

echo "install, uninstall, rollback, restore, ipv6, rkn"
begin docker
SRC=$WORK/src
write_pair "$SRC" 8
bash "$CLI" install >/dev/null
bash "$CLI" install >/dev/null
jumps=$(python3 "$PY" audit --base "$REMNA_SECURITY_BASE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["guard_jumps"])')
[ "$jumps" = 1 ] || fail "install not idempotent jumps=$jumps"
bash "$CLI" config-set FILTER_PORTS 443,8443 >/dev/null
grep -q '^FILTER_PORTS=443,8443$' "$REMNA_SECURITY_BASE/settings.conf" || fail "port change missing"
bash "$CLI" rollback >/dev/null
grep -q '^FILTER_PORTS=443$' "$REMNA_SECURITY_BASE/settings.conf" || fail "rollback did not restore ports"
doc=$(bash "$CLI" selftest --json)
require_json "$doc" remna-security.selftest.v1
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["ok"] is True, d' "$doc"
bash "$CLI" config-set PANEL_IP 2001:db8::10 >/dev/null
python3 - <<PY
import json
state=json.load(open("$REMNA_SECURITY_BASE/sim/state.json"))
rules6="\\n".join(state["chains6"]["REMNA_GUARD6"])
rules4="\\n".join(state["chains"]["REMNA_GUARD"])
assert "2001:db8::10" in rules6
assert "203.0.113.10" not in rules4
assert "--dport 2222" in rules4 and "-j DROP" in rules4
PY
st=$(bash "$CLI" status --json)
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["ipv6"]["dynamic_lists"] is False and d["node_api_2222"]=="protected"' "$st"
bash "$CLI" config-set PANEL_IP 203.0.113.10 >/dev/null
bash "$CLI" rkn-disable >/dev/null
python3 - <<PY
import json
state=json.load(open("$REMNA_SECURITY_BASE/sim/state.json"))
rules="\\n".join(state["chains"]["REMNA_GUARD"])
assert "remna:tspu" not in rules
assert "remna:gov" not in rules
assert "--dport 2222" in rules
PY
bash "$CLI" uninstall >/dev/null
[ -f "$REMNA_SECURITY_BASE/settings.conf" ] || fail "config removed"
python3 - <<PY
import json
state=json.load(open("$REMNA_SECURITY_BASE/sim/state.json"))
assert "REMNA_GUARD" not in state["chains"]
assert any("--dport 22" in r for r in state["input"])
assert state["docker_chains"]
text="\\n".join(state["last_commands"])
assert "-F INPUT" not in text
assert "nft flush ruleset" not in text
PY
grep -q 'LogRateLimitIntervalSec=30s' "$REMNA_SECURITY_BASE/sim/units/remna-protection.service"
grep -q 'OnCalendar=Sun' "$REMNA_SECURITY_BASE/sim/units/remna-protection-update.timer"
grep -q 'copytruncate' "$REMNA_SECURITY_BASE/sim/logrotate.conf"
grep -q 'protection-manager.sh' "$REMNA_SECURITY_BASE/sim/units/remna-protection.service"
ok lifecycle

echo "nftables isolated, refused beside docker/ufw"
begin docker
pre=$(bash "$CLI" preflight nftables --json || true)
require_json "$pre" remna-security.preflight.v1
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["ok"] is False and "docker" in d["nft_refuse_reason"], d' "$pre"
set +e
bash "$CLI" backend-switch nftables --confirm >/dev/null
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "nft switch allowed beside docker"
grep -q '^BACKEND=iptables$' "$REMNA_SECURITY_BASE/settings.conf" || fail "backend changed despite refusal"
begin isolated
SRC=$WORK/src
write_pair "$SRC" 6
bash "$CLI" apply >/dev/null
bash "$CLI" backend-switch nftables --confirm >/dev/null
python3 - <<PY
import json
state=json.load(open("$REMNA_SECURITY_BASE/sim/state.json"))
assert state["owned_backend"] == "nftables"
assert "tcp dport 2222 drop" in state["nft_table"]
assert "203.0.113.10" in state["nft_table"]
assert state["chains"] == {}
assert any("--dport 22" in r for r in state["input"])
assert not any("-j REMNA_GUARD" in r.split()[-2:] and r.split()[-1]=="REMNA_GUARD" for r in state["input"])
text="\\n".join(state["last_commands"])
assert "nft flush ruleset" not in text
assert "-F INPUT" not in text
PY
bash "$CLI" backend-switch iptables --confirm >/dev/null
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert s["owned_backend"]=="iptables" and s["nft_table"]=="" and "REMNA_GUARD" in s["chains"]' "$REMNA_SECURITY_BASE/sim/state.json"
ok nftables

echo "ufw coexistence"
begin ufw
SRC=$WORK/src
write_pair "$SRC" 4
bash "$CLI" apply >/dev/null
python3 - <<PY
import json
state=json.load(open("$REMNA_SECURITY_BASE/sim/state.json"))
assert state["ufw_active"] is True
assert any(r.startswith("22/tcp") for r in state["ufw_rules"])
assert not any(r.startswith("2222/tcp") and "Anywhere" in r for r in state["ufw_rules"])
assert any("203.0.113.10" in r for r in state["ufw_rules"])
text="\\n".join(state["last_commands"])
assert "reset" not in text
assert "DOCKER" in " ".join(state.get("docker_chains") or [])
PY
ok ufw

echo "scanner fast feed and migrate"
begin docker
SRC=$WORK/src
write_pair "$SRC" 8
nets 15 20 > "$WORK/scanners.txt"
export REMNA_SECURITY_SOURCE_SCANNERS=file://$WORK/scanners.txt
bash "$CLI" config-set ENABLE_SCANNERS 1 >/dev/null
bash "$CLI" update --json > "$WORK/scan.json" || fail scanner-update
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["ok"] and any(s["id"]=="scanners" and s["ok"] for s in d["sources"])' "$WORK/scan.json"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert "remna:scanners" in "\\n".join(s["chains"]["REMNA_GUARD"])' "$REMNA_SECURITY_BASE/sim/state.json"
# legacy config without new keys
cat > "$REMNA_SECURITY_BASE/settings.conf" <<'EOF'
PANEL_IP=203.0.113.10
ENABLE_TSPU=1
ENABLE_GOV=1
ENABLE_GEOIP=0
FILTER_PORTS=443
GEO_COUNTRIES=
EOF
printf '192.0.2.55/32\n' > "$REMNA_SECURITY_BASE/data/allow.txt"
bash "$CLI" migrate-inplace >/dev/null
grep -q '^BACKEND=iptables$' "$REMNA_SECURITY_BASE/settings.conf" || fail "migrate dropped backend default"
grep -q '^PANEL_IP=203.0.113.10$' "$REMNA_SECURITY_BASE/settings.conf" || fail "migrate lost panel"
grep -q '192.0.2.55/32' "$REMNA_SECURITY_BASE/data/allow.txt" || fail "migrate lost allow"
grep -q '192.0.2.55/32' "$REMNA_SECURITY_BASE/data/lkg/allow.txt" || fail "lkg not seeded"
ok scanners-migrate

echo "event rate limit and preflight json"
begin docker
python3 "$PY" event --base "$REMNA_SECURITY_BASE" --kind source_error --message tspu:html
python3 "$PY" event --base "$REMNA_SECURITY_BASE" --kind source_error --message tspu:html
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert len(d)==1' "$REMNA_SECURITY_BASE/data/recent.json"
doc=$(bash "$CLI" preflight --json)
require_json "$doc" remna-security.preflight.v1
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["ok"] is True and d["owns_only"] is True and d["docker_present"] is True' "$doc"
ok preflight

echo "live apply is refused"
rc=0
env -u REMNA_SECURITY_SIM REMNA_SECURITY_FORBID_LIVE=1 REMNA_SECURITY_BASE="$REMNA_SECURITY_BASE" python3 "$PY" apply --base "$REMNA_SECURITY_BASE" > "$WORK/live.out" 2> "$WORK/live.err" || rc=$?
[ "$rc" -eq 2 ] || fail "live apply rc=$rc"
grep -q 'forbidden' "$WORK/live.err" || fail "live apply missing refusal"
ok forbid-live

printf 'PASS %s\n' "$PASS"

echo "security v2 offline"
bash "$ROOT/tests/security/v2/run.sh"
ok v2
