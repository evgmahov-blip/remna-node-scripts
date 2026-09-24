#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
M="$ROOT/next-installer/telemt-manager.sh"

bash -n "$M"

must(){ grep -Fq -- "$1" "$M" || { echo "missing invariant: $1" >&2; exit 1; }; }
must_not(){ ! grep -Fq -- "$1" "$M" || { echo "forbidden pattern: $1" >&2; exit 1; }; }

must 'TELEMT_PORT="${TELEMT_PORT:-8443}"'
must '127.0.0.1:9091'
must '127.0.0.1:8080'
must 'mode = "tracked"'
must 'inline_conntrack_control = false'
must 'service_manager = "none"'
must 'mode = "manual"'
must 'CapabilityBoundingSet='
must 'AmbientCapabilities='
must 'NoNewPrivileges=true'
must 'ensure_protection_port'
must 'config-set FILTER_PORTS'
must 'protection covers TCP/'
must '80/443 are intentionally forbidden'

must_not 'iptables -F'
must_not 'iptables -A'
must_not 'nft flush ruleset'
must_not 'ufw reset'
must_not 'docker.sock'
must_not 'network_mode: host'
must_not 'CAP_NET_ADMIN'
must_not 'CAP_NET_BIND_SERVICE'

echo "telemt integration static security tests: OK"
