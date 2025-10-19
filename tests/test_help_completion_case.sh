#!/bin/bash
# Test for case-insensitive help completion

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Source the completion script
# shellcheck disable=SC1091
source "$REPO_ROOT/contrib/bar_complete"

echo "Testing help completion case sensitivity..."

# Initialize completion registry
__bar_init_completion_registry

# Set up the invocation to use the bar in the repo
__bar_invocation="$REPO_ROOT/bar"

# Test 1: Check if lowercase "qu" completes to something starting with "qu"
# This simulates what bash does - it filters completions by prefix match
echo ""
echo "Test 1: Lowercase 'qu' should complete to something starting with 'qu'"
result=$(__bar_comp_help "qu")
# Filter results like bash would (case-sensitive prefix match)
filtered=$(echo "$result" | grep "^qu")
if [[ -n "$filtered" ]]; then
    echo "✓ PASS: 'qu' completes to case-matching result"
    echo "  Result: $filtered"
else
    echo "✗ FAIL: 'qu' did not complete to anything starting with 'qu' (bash would reject)"
    echo "  Returned: $result (doesn't match prefix 'qu')"
fi

# Test 2: Check if "QU" completes to "QUICKSTART" (preserving case)
echo ""
echo "Test 2: Uppercase 'QU' should complete to QUICKSTART"
result=$(__bar_comp_help "QU")
if echo "$result" | grep -q "QUICKSTART"; then
    echo "✓ PASS: 'QU' completes to QUICKSTART (preserving case)"
    echo "  Result: $result"
else
    echo "✗ FAIL: 'QU' did not complete to QUICKSTART"
    echo "  Result: $result"
fi

# Test 3: Check if "Qu" (mixed case) completes appropriately (preserves case)
echo ""
echo "Test 3: Mixed case 'Qu' should complete to QUICKSTART (preserving case)"
result=$(__bar_comp_help "Qu")
# Filter results like bash would (case-sensitive prefix match)
filtered=$(echo "$result" | grep "^Qu")
if [[ -n "$filtered" ]]; then
    echo "✗ FAIL: 'Qu' should preserve original case QUICKSTART, not match 'Qu'"
    echo "  Result: $filtered"
elif echo "$result" | grep -q "^QUICKSTART"; then
    echo "✓ PASS: 'Qu' completes to QUICKSTART (preserving original case)"
    echo "  Result: $result"
else
    echo "✗ FAIL: 'Qu' did not complete properly"
    echo "  Result: $result"
fi

# Test 4: Empty input should return all help topics
echo ""
echo "Test 4: Empty input should return help topics"
result=$(__bar_comp_help "")
if [[ -n "$result" ]]; then
    count=$(echo "$result" | wc -l)
    echo "✓ PASS: Empty input returns $count help topics"
else
    echo "✗ FAIL: Empty input returned nothing"
fi

echo ""
echo "Help completion case tests complete"
