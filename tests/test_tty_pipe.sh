#!/usr/bin/env bash
# Simple test for tty_newline not hanging when piped

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Testing tty functions when piped..."

# Test piping bar output
cd "$REPO_ROOT"
if echo "rule test: echo 'ok'" | timeout 3 ./bar - test 2>&1 | cat >/dev/null; then
    echo "✓ PASS: Bar with piped output completed"
else
    rc=$?
    if [[ $rc -eq 124 ]]; then
        echo "✗ FAIL: Timed out (hung)"
        exit 1
    fi
fi

echo "All pipe tests passed!"
