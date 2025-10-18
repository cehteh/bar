#!/bin/bash
# Test prototype scoping to ensure module prototypes don't override globals

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Source the completion script
# shellcheck source=../contrib/bar_complete
source "$REPO_ROOT/contrib/bar_complete"

echo "==================================="
echo "Prototype Scoping Tests"
echo "==================================="
echo ""

# Test 1: Module prototypes should be scoped
echo "Test 1: Module prototypes are scoped to module@prototype"
_bar_init_completion_registry
_bar_complete_parse_file "$REPO_ROOT/Bar.d/help"

if [[ "${_bar_complete_protoregistry[help@rule]}" == "help" ]]; then
    echo "  ✓ PASS: help@rule is registered as 'help'"
else
    echo "  ✗ FAIL: help@rule should be 'help' but is: ${_bar_complete_protoregistry[help@rule]}"
    exit 1
fi

if [[ "${_bar_complete_protoregistry[rule]}" == "rule_or_function" ]]; then
    echo "  ✓ PASS: Global 'rule' remains 'rule_or_function'"
else
    echo "  ✗ FAIL: Global 'rule' should be 'rule_or_function' but is: ${_bar_complete_protoregistry[rule]}"
    exit 1
fi

echo ""

# Test 2: Non-module files should NOT register global prototypes
echo "Test 2: Prototype definitions in non-module files are ignored"
cat > /tmp/test_barf << 'EOF'
# prototype: "testproto" = "help"

rule test:
    echo "test"
EOF

# Clear and reinit
unset _bar_complete_protoregistry
declare -gA _bar_complete_protoregistry=()
_bar_init_completion_registry

# Parse the non-module file (no module context)
_bar_complete_parse_file --public /tmp/test_barf

if [[ -z "${_bar_complete_protoregistry[testproto]:-}" ]]; then
    echo "  ✓ PASS: testproto was not registered globally (correctly ignored)"
else
    echo "  ✗ FAIL: testproto should not be registered globally, but is: ${_bar_complete_protoregistry[testproto]}"
    rm /tmp/test_barf
    exit 1
fi

rm /tmp/test_barf
echo ""

# Test 3: Verify help@rule only used in help module context
echo "Test 3: help@rule completer is only used in help module context"

# Clear registries
unset _bar_complete_protoregistry
unset _bar_completion_func_module
declare -gA _bar_complete_protoregistry=()
declare -gA _bar_completion_func_module=()

_bar_init_completion_registry
_bar_scan_files "./bar"

# Get completer for 'rule' without any function context
completer=$(_bar_get_completer "" "rule")
if [[ "$completer" == "_bar_complete_comp_rule_or_function" ]]; then
    echo "  ✓ PASS: 'rule' without context uses rule_or_function completer"
else
    echo "  ✗ FAIL: 'rule' without context should use rule_or_function but got: $completer"
    exit 1
fi

# Get completer for 'rule' in context of help function
completer=$(_bar_get_completer "help" "rule")
if [[ "$completer" == "_bar_complete_comp_help" ]]; then
    echo "  ✓ PASS: 'rule' in help context uses help completer"
else
    echo "  ✗ FAIL: 'rule' in help context should use help completer but got: $completer"
    exit 1
fi

# Get completer for 'rule' in context of some other function
_bar_completion_functions+=("other_func")
completer=$(_bar_get_completer "other_func" "rule")
if [[ "$completer" == "_bar_complete_comp_rule_or_function" ]]; then
    echo "  ✓ PASS: 'rule' in other_func context uses rule_or_function completer"
else
    echo "  ✗ FAIL: 'rule' in other_func context should use rule_or_function but got: $completer"
    exit 1
fi

echo ""

# Test 4: Verify cargo module prototypes are also scoped
echo "Test 4: Cargo module prototypes are properly scoped"

if [[ "${_bar_complete_protoregistry[cargo@toolchain]}" == "extcomp cargo" ]]; then
    echo "  ✓ PASS: cargo@toolchain is registered"
else
    echo "  ✗ FAIL: cargo@toolchain should be registered but is: ${_bar_complete_protoregistry[cargo@toolchain]:-NOT SET}"
    exit 1
fi

# Global 'toolchain' should not exist
if [[ -z "${_bar_complete_protoregistry[toolchain]:-}" ]]; then
    echo "  ✓ PASS: Global 'toolchain' is not registered (module-scoped only)"
else
    echo "  ✗ FAIL: Global 'toolchain' should not exist but is: ${_bar_complete_protoregistry[toolchain]}"
    exit 1
fi

echo ""
echo "==================================="
echo "All prototype scoping tests passed!"
echo "==================================="
