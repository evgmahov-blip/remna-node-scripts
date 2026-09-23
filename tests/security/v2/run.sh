#!/usr/bin/env bash
# Offline Security V2 tests. No network, no host firewall, no live Xray.
set -Eeuo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"
export REMNA_SECURITY_SIM=1
export REMNA_SECURITY_FORBID_LIVE=1
python3 -m unittest discover -s "$ROOT/tests/security/v2" -p 'test_*.py'
