#!/bin/bash
# Test --public mode for __bar_parse_file

cd "$(dirname "$0")/.." || exit
source contrib/bar_complete

echo "=== Testing --public Mode ==="
echo ""

# Test 1: Default mode (only documented rules)
echo "Test 1: Parse example without --public (only documented rules)"
__bar_rules=()
__bar_functions=()
__bar_parse_file "example"
if [ ${#__bar_rules[@]} -eq 0 ]; then
    echo "  ✓ PASS: No undocumented rules found (0 rules)"
else
    echo "  ✗ FAIL: Found ${#__bar_rules[@]} rules (expected 0)"
fi
echo ""

# Test 2: Public mode (all rules)
echo "Test 2: Parse example with --public (all rules)"
__bar_rules=()
__bar_functions=()
__bar_parse_file --public "example"
if [ ${#__bar_rules[@]} -gt 20 ]; then
    echo "  ✓ PASS: Found ${#__bar_rules[@]} rules (including undocumented)"
    echo "  Sample rules: ${__bar_rules[*]:0:5}"
else
    echo "  ✗ FAIL: Found only ${#__bar_rules[@]} rules (expected >20)"
fi
echo ""

# Test 3: Bar.d modules should only show documented rules
echo "Test 3: Parse Bar.d/git_rules without --public"
__bar_rules=()
__bar_functions=()
if [ -f "Bar.d/git_rules" ]; then
    __bar_parse_file "Bar.d/git_rules"
    if [ ${#__bar_rules[@]} -gt 0 ]; then
        echo "  ✓ PASS: Found ${#__bar_rules[@]} documented git rules"
    else
        echo "  ✗ FAIL: No rules found in Bar.d/git_rules"
    fi
else
    echo "  ⊘ SKIP: Bar.d/git_rules not found"
fi
echo ""

# Test 4: Completion after specifying rulefile
echo "Test 4: bar example <TAB> should complete with example rules"
COMP_WORDS=(bar "example" "")
COMP_CWORD=2
_bar_complete

has_example_ok=false
has_example_fail=false
for comp in "${COMPREPLY[@]}"; do
    [[ "$comp" == "example_ok" ]] && has_example_ok=true
    [[ "$comp" == "example_fail" ]] && has_example_fail=true
done

if [ "$has_example_ok" = true ] && [ "$has_example_fail" = true ]; then
    echo "  ✓ PASS: Rules from example file are in completions"
else
    echo "  ✗ FAIL: Rules from example file NOT in completions"
fi
echo ""

# Test 5: Default rulefile should use --public
echo "Test 5: _bar_scan_files should parse default Barf with --public"
__bar_scan_files bar
if [ ${#__bar_rules[@]} -gt 0 ]; then
    echo "  ✓ PASS: Default Barf parsed, found ${#__bar_rules[@]} rules"
else
    echo "  ✗ FAIL: No rules found from default Barf"
fi
echo ""

echo "=== All Tests Complete ==="
