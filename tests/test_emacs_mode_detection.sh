#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
# shellcheck shell=bash

### Test Emacs mode detection for Bar.d modules and related files
### This test is informational only and always exits successfully.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Testing Emacs mode detection (informational)..."

# Test if emacs is available
if ! command -v emacs &>/dev/null; then
    echo "WARNING: emacs not installed, skipping mode detection test"
    exit 0
fi

# Test each file
warnings=0
test_files=(
    "Bar.d/help"
    "Bar.d/cargo"
    "Bar.d/git_lib"
    "Barf"
    "Barf.default"
    "Pleasef.default"
    "bar"
)

for file in "${test_files[@]}"; do
    test_file="$REPO_ROOT/$file"
    
    if [[ ! -f "$test_file" ]]; then
        echo "WARNING: $file not found"
        warnings=$((warnings + 1))
        continue
    fi
    
    # Use emacs to check mode detection via set-auto-mode
    # Ignore errors since some emacs builds may lack sh-mode support
    mode=$(emacs --batch \
        --eval "(find-file \"$test_file\")" \
        --eval '(message "MODE: %s" (symbol-name major-mode))' \
        2>&1 | grep "^MODE:" | head -1 | sed 's/^MODE: //' || true)
    
    if [[ "$mode" == "sh-mode" ]]; then
        echo "✓ $file detected as sh-mode"
    elif [[ -z "$mode" ]]; then
        echo "WARNING: Could not determine mode for $file"
        warnings=$((warnings + 1))
    else
        echo "WARNING: $file detected as $mode (expected sh-mode)"
        warnings=$((warnings + 1))
    fi
done

if [[ $warnings -gt 0 ]]; then
    echo "WARNING: $warnings file(s) had issues with Emacs mode detection"
fi

echo "Emacs mode detection test completed (exit status: success)"
exit 0
