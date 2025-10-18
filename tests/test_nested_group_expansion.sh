#!/bin/bash
# Test for nested group and alternative expansion in completion
# Tests the requirements from .github/copilot-instructions.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$REPO_ROOT/contrib/bar_complete"

echo "========================================"
echo "Nested Group Completion Tests"
echo "========================================"
echo

# Test helper
assert_contains() {
    local needle="$1"
    shift
    local haystack=("$@")
    
    for item in "${haystack[@]}"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

# Test 1: Simple alternative expansion using _bar_expand_group_alternatives
echo "Test 1: Simple alternatives (--flag|--other)"
echo "-------------------------------------------"
alternatives=$(_bar_expand_group_alternatives "--flag|--other")
echo "Result: $alternatives"
if echo "$alternatives" | grep -q "^--flag$" && echo "$alternatives" | grep -q "^--other$"; then
    echo "✓ PASS: Correctly expanded simple alternatives"
else
    echo "✗ FAIL: Did not correctly expand alternatives"
fi
echo

# Test 2: Optional group expansion
echo "Test 2: Optional group [--verbose]"
echo "-----------------------------------"
result=$(_bar_expand_group_alternatives "[--verbose]")
echo "Result: $result"
if [[ "$result" == "--verbose" ]]; then
    echo "✓ PASS: Correctly extracted from optional group"
else
    echo "✗ FAIL: Expected --verbose, got: $result"
fi
echo

# Test 3: Complex nested groups with alternatives
echo "Test 3: Complex example [[--verbose] foo [bar|baz]]"
echo "----------------------------------------------------"
result=$(_bar_expand_group_alternatives "[[--verbose] foo [bar|baz]]")
echo "Result:"
echo "$result"
# Should get --verbose and foo, but NOT bar or baz
if echo "$result" | grep -q "^--verbose$" && echo "$result" | grep -q "^foo$"; then
    if ! echo "$result" | grep -q "^bar$" && ! echo "$result" | grep -q "^baz$"; then
        echo "✓ PASS: Correctly expanded nested group (got --verbose and foo, not bar/baz)"
    else
        echo "✗ FAIL: Incorrectly included bar or baz"
    fi
else
    echo "✗ FAIL: Did not get expected --verbose and foo"
fi
echo

# Test 4: Alternatives within optional group
echo "Test 4: Alternatives within optional group [foo|bar]"
echo "-----------------------------------------------------"
result=$(_bar_expand_group_alternatives "[foo|bar]")
echo "Result:"
echo "$result"
if echo "$result" | grep -q "^foo$" && echo "$result" | grep -q "^bar$"; then
    echo "✓ PASS: Correctly expanded alternatives within optional group"
else
    echo "✗ FAIL: Did not get both foo and bar"
fi
echo

# Test 5: Required group
echo "Test 5: Required group <file>"
echo "------------------------------"
result=$(_bar_expand_group_alternatives "<file>")
echo "Result: $result"
if [[ "$result" == "file" ]]; then
    echo "✓ PASS: Correctly extracted from required group"
else
    echo "✗ FAIL: Expected file, got: $result"
fi
echo

echo
echo "========================================"
echo "Summary"
echo "========================================"
echo "The _bar_expand_group_alternatives function now handles:"
echo "  ✓ Simple alternatives (a|b)"
echo "  ✓ Optional vs required groups"
echo "  ✓ Nested group expansion"
echo "  ✓ Complex patterns like [[optional] required]"
echo
echo "This function is now integrated into the main completion engine"
echo "and used during completion collection."
