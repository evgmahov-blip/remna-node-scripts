#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/../.."
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH=.
python3 -m unittest discover -s tests/cheburnet_adoption -p 'test_*.py' -v
