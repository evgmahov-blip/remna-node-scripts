#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/run"
cat > "$TMP/run/summary.tsv" <<'DATA'
num	name	status	duration	rc
4	iPerf	PASS	1	0
5	Disk	PASS	1	0
8	CPU	PASS	1	0
9	HTTPS	PASS	1	0
DATA
cat > "$TMP/run/09-network-bench.log" <<'DATA'
Average:    800.00 Mbit/s
DATA
cat > "$TMP/run/08-sysbench-cpu.log" <<'DATA'
CPU single-thread:
events per second: 1000.00
CPU all-thread (4 threads):
events per second: 3900.00
DATA
cat > "$TMP/run/04-iperf-ru.log" <<'DATA'
Server Download Upload Ping
RU-1 900 Mbps 700 Mbps 20 ms
RU-2 850 Mbps 680 Mbps 25 ms
DATA
cat > "$TMP/run/05-yabs-disk.log" <<'DATA'
fio Disk Speed Tests
Block Size | 4k
Read 500 MB/s | 120k IOPS
Write 450 MB/s | 110k IOPS
DATA
cat > "$TMP/run/11-nexttrace-mtu.log" <<'DATA'
Path MTU: 1500
DATA
cat > "$TMP/run/07-ipquality.log" <<'DATA'
DNSBL: clean=50 marked=0 blacklisted=0
DATA

REMNANODE_MULTITEST_SOURCE_ONLY=1 source <(sed '$d' "$ROOT/next-installer/server-multitest.sh")
out="$(print_node_scorecard "$TMP/run")"
printf '%s\n' "$out"
grep -Fq 'АНАЛИЗ НОДЫ — ПРОИЗВОДИТЕЛЬНОСТЬ И СЕТЬ' <<<"$out"
grep -Fq 'HTTPS download:    800.00 Mbit/s' <<<"$out"
grep -Fq 'RU-1 900 Mbps 700 Mbps 20 ms' <<<"$out"
grep -Fq 'CPU single:        1000.00 events/s' <<<"$out"
grep -Fq 'Read 500 MB/s | 120k IOPS' <<<"$out"
grep -Fq 'Рабочий бюджет:    560.0 Mbit/s' <<<"$out"
grep -Fq 'XHTTP @3 Mbit/s:   ~186' <<<"$out"
grep -Fq 'XHTTP @5 Mbit/s:   ~112' <<<"$out"
grep -Fq 'Path MTU:          1500' <<<"$out"
echo 'PASS node analysis scorecard'
