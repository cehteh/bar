#!/bin/bash
# Test completion outside bar repository
# Reproducer for bug where completion fails when not in bar directory

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

echo "======================================"
echo "Test: Completion Outside Bar Repository"
echo "======================================"
echo

# Create a temp directory outside the repository
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR" || exit 1

# shellcheck disable=SC1091
source "$REPO_ROOT/contrib/bar_complete"

echo "Test: Scanning for rules/functions from temp directory: $TEMP_DIR"
__bar_scan_files "bar"

echo "Rules found: ${#__bar_rules[@]}"
echo "Functions found: ${#__bar_functions[@]}"

# Check if any rules were found
if [[ ${#__bar_rules[@]} -gt 0 ]]; then
    echo "✓ PASS: Found ${#__bar_rules[@]} rules"
    echo "  Sample rules: ${__bar_rules[0]}, ${__bar_rules[1]}, ${__bar_rules[2]}"
else
    echo "✗ FAIL: No rules found when outside bar repository"
    echo "  Expected: Should fall back to installed Bar.d location"
fi

# Check if any functions were found
if [[ ${#__bar_functions[@]} -gt 0 ]]; then
    echo "✓ PASS: Found ${#__bar_functions[@]} functions"
else
    echo "✗ FAIL: No functions found when outside bar repository"
fi

# Cleanup
cd - > /dev/null || exit 1
rm -rf "$TEMP_DIR"

echo
echo "Test complete"
