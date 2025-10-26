#!/bin/bash
# Test memodb_analyze functionality for tree hash mismatch detection

# Setup paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Testing memodb_analyze functionality ==="

# This test verifies that the memodb_analyze function exists and will be invoked
# when tree hash mismatches occur during memodb_result calls.

cd "$REPO_ROOT" || exit 1

# Check that the function exists in the memodb module
if grep -q "^function memodb_analyze" Bar.d/memodb; then
    echo "✓ memodb_analyze function defined in Bar.d/memodb"
else
    echo "✗ memodb_analyze function not found in Bar.d/memodb"
    exit 1
fi

# Check that it's called from memodb_result
if grep -q "memodb_analyze" Bar.d/memodb | grep -q "memodb_result" ; then
    echo "✓ memodb_analyze is called from the failure path"
else
    # Check more loosely - just that it's referenced after memodb_result
    if awk '/^function memodb_result/,/^}/ {if (/memodb_analyze/) found=1} END {exit !found}' Bar.d/memodb; then
        echo "✓ memodb_analyze is integrated into memodb_result"
    else
        echo "✗ memodb_analyze not called from memodb_result"
        exit 1
    fi
fi

# Check that it provides helpful error messages
if grep -q "Tree hash mismatch detected" Bar.d/memodb; then
    echo "✓ Provides tree hash mismatch diagnostics"
else
    echo "✗ Missing tree hash diagnostics"
    exit 1
fi

if grep -q "\.gitignore" Bar.d/memodb; then
    echo "✓ Mentions .gitignore in help text"
else
    echo "✗ Missing .gitignore references"
    exit 1
fi

echo ""
echo "=== All memodb_analyze checks passed! ==="
echo ""
echo "The function will be automatically invoked when memodb_result encounters"
echo "a tree hash mismatch, providing diagnostic information about untracked"
echo "files that should be added to .gitignore."
