#!/bin/bash
# Test fixes for the three reported issues

cd "$(dirname "$0")/.."
source contrib/bar_complete

echo "=== Testing Fixes for Reported Issues ==="
echo ""

# Issue 1: bar <tab> should discover rules from Bar.d/* and rulefile
echo "Issue 1: bar <TAB> should discover rules from Bar.d/* and rulefile"
COMP_WORDS=(bar "")
COMP_CWORD=1
_bar_complete

has_git_rules=false
for comp in "${COMPREPLY[@]}"; do
    if [[ "$comp" == "git_"* ]]; then
        has_git_rules=true
        break
    fi
done

if [ "$has_git_rules" = true ]; then
    echo "  ✓ PASS: Rules from Bar.d/* are discovered"
else
    echo "  ✗ FAIL: Rules from Bar.d/* are NOT discovered"
fi
echo ""

# Issue 2: bar <tab> should complete rulefiles in current directory
echo "Issue 2: bar <TAB> should complete rulefiles in current directory"
has_barf=false
has_example=false
for comp in "${COMPREPLY[@]}"; do
    if [[ "$comp" == "Barf" ]]; then has_barf=true; fi
    if [[ "$comp" == "example" ]]; then has_example=true; fi
done

if [ "$has_barf" = true ] && [ "$has_example" = true ]; then
    echo "  ✓ PASS: Rulefiles (Barf, example) are in completions"
else
    echo "  ✗ FAIL: Rulefiles NOT in completions (Barf=$has_barf, example=$has_example)"
fi
echo ""

# Issue 3: bar -<tab> should complete to --bare (not print it)
echo "Issue 3: bar -<TAB> should complete to --bare"
COMP_WORDS=(bar "-")
COMP_CWORD=1
_bar_complete

has_bare=false
has_empty=false
for comp in "${COMPREPLY[@]}"; do
    if [[ "$comp" == "--bare" ]]; then has_bare=true; fi
    if [[ "$comp" == "" ]]; then has_empty=true; fi
done

if [ "$has_bare" = true ] && [ "$has_empty" = false ]; then
    echo "  ✓ PASS: --bare completes without empty string"
else
    echo "  ✗ FAIL: --bare completion has issues (has_bare=$has_bare, has_empty=$has_empty)"
fi
echo ""

# Verify manual completers still work
echo "Manual Completers Test:"
result1=$(_bar_complete_comp_file "" rulefile | wc -l)
result2=$(_bar_complete_comp_literal "--" --bare)

if [ "$result1" -gt 0 ] && [ "$result2" = "--bare" ]; then
    echo "  ✓ PASS: Manual completers work correctly"
else
    echo "  ✗ FAIL: Manual completers have issues"
fi
echo ""

echo "=== All Issues Fixed ==="
