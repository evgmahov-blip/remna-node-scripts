#!/usr/bin/env bash
# Compatibility entrypoint for the existing Remna protection CLI.
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export REMNA_SECURITY_ENTRY="$HERE/protection-manager.sh"
exec bash "$HERE/security/remna-security.sh" "$@"
