#!/bin/bash
# Test the specific user requirements from the issue

cd "$(dirname "$0")/.." || exit 1
source contrib/bar_complete

echo "=========================================="
echo "User Requirement Tests"
echo "=========================================="
echo ""

# Test 1: bar <tab> should include rules from default rulefile
echo "Test 1: bar <tab> includes rules from default rulefile"
COMP_WORDS=(bar "")
COMP_CWORD=1
_bar_complete
total=${#COMPREPLY[@]}
echo "  Total completions: $total"

# Check for some expected rules from Barf
has_tests=false
has_lints=false
has_barf=false
for comp in "${COMPREPLY[@]}"; do
    [[ "$comp" == "tests" ]] && has_tests=true
    [[ "$comp" == "lints" ]] && has_lints=true
    [[ "$comp" == "Barf" ]] && has_barf=true
done

if [[ $has_tests == true && $has_lints == true && $has_barf == true ]]; then
    echo "  ✓ Found expected rules and rulefiles from default Barf"
else
    echo "  ✗ Missing expected rules"
    echo "    has_tests=$has_tests has_lints=$has_lints has_barf=$has_barf"
fi

# Test 2: bar semver<tab> should complete semver functions from Bar.d/semver_lib
echo ""
echo "Test 2: bar semver<tab> completes semver functions from Bar.d/"
COMP_WORDS=(bar "semver")
COMP_CWORD=1
_bar_complete
total=${#COMPREPLY[@]}
echo "  Completions starting with 'semver': $total"

has_semver_parse=false
has_semver_validate=false
for comp in "${COMPREPLY[@]}"; do
    [[ "$comp" == "semver_parse" ]] && has_semver_parse=true
    [[ "$comp" == "semver_validate" ]] && has_semver_validate=true
done

if [[ $total -gt 10 && $has_semver_parse == true && $has_semver_validate == true ]]; then
    echo "  ✓ Found semver functions from Bar.d/semver_lib"
else
    echo "  ✗ Missing semver functions"
    echo "    total=$total has_semver_parse=$has_semver_parse has_semver_validate=$has_semver_validate"
fi

# Test 3: bar example <tab> should include rules from example file
echo ""
echo "Test 3: bar example <tab> includes rules from example file"
COMP_WORDS=(bar example "")
COMP_CWORD=2
_bar_complete
total=${#COMPREPLY[@]}
echo "  Total completions: $total"

has_example_ok=false
has_example_fail=false
has_test_memodb=false
for comp in "${COMPREPLY[@]}"; do
    [[ "$comp" == "example_ok" ]] && has_example_ok=true
    [[ "$comp" == "example_fail" ]] && has_example_fail=true
    [[ "$comp" == "test_memodb" ]] && has_test_memodb=true
done

if [[ $has_example_ok == true && $has_example_fail == true && $has_test_memodb == true ]]; then
    echo "  ✓ Found expected rules from example file"
else
    echo "  ✗ Missing expected rules from example"
    echo "    has_example_ok=$has_example_ok has_example_fail=$has_example_fail has_test_memodb=$has_test_memodb"
fi

echo ""
echo "=========================================="
echo "All tests complete"
echo "=========================================="
