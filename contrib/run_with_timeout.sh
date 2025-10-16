#!/usr/bin/env bash
# Wrapper to run commands with a default timeout, override via COMMAND_TIMEOUT
set -euo pipefail

TIMEOUT_DURATION="${COMMAND_TIMEOUT:-15s}"

if [[ $# -eq 0 ]]; then
    echo "usage: run_with_timeout <command> [args...]" >&2
    exit 64
fi

exec timeout "$TIMEOUT_DURATION" "$@"
