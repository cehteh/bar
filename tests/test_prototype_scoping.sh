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
__bar_init_completion_registry
__bar_parse_file "$REPO_ROOT/Bar.d/help"

if [[ "${__bar_protoregistry[help@rule]}" == "help" ]]; then
    echo "  ✓ PASS: help@rule is registered as 'help'"
else
    echo "  ✗ FAIL: help@rule should be 'help' but is: ${__bar_protoregistry[help@rule]}"
    exit 1
fi

if [[ "${__bar_protoregistry[rule]}" == "rule_or_function" ]]; then
    echo "  ✓ PASS: Global 'rule' remains 'rule_or_function'"
else
    echo "  ✗ FAIL: Global 'rule' should be 'rule_or_function' but is: ${__bar_protoregistry[rule]}"
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
unset __bar_protoregistry
declare -gA __bar_protoregistry=()
__bar_init_completion_registry

# Parse the non-module file (no module context)
__bar_parse_file --public /tmp/test_barf

if [[ -z "${__bar_protoregistry[testproto]:-}" ]]; then
    echo "  ✓ PASS: testproto was not registered globally (correctly ignored)"
else
    echo "  ✗ FAIL: testproto should not be registered globally, but is: ${__bar_protoregistry[testproto]}"
    rm /tmp/test_barf
    exit 1
fi

rm /tmp/test_barf
echo ""

# Test 3: Verify help@rule only used in help module context
echo "Test 3: help@rule completer is only used in help module context"

# Clear registries
unset __bar_protoregistry
unset __bar_func_module
declare -gA __bar_protoregistry=()
declare -gA __bar_func_module=()

__bar_init_completion_registry
__bar_scan_files "./bar"

# Get completer for 'rule' without any function context
completer=$(__bar_get_completer "" "rule")
if [[ "$completer" == "__bar_comp_rule_or_function" ]]; then
    echo "  ✓ PASS: 'rule' without context uses rule_or_function completer"
else
    echo "  ✗ FAIL: 'rule' without context should use rule_or_function but got: $completer"
    exit 1
fi

# Get completer for 'rule' in context of help function
completer=$(__bar_get_completer "help" "rule")
if [[ "$completer" == "__bar_comp_help" ]]; then
    echo "  ✓ PASS: 'rule' in help context uses help completer"
else
    echo "  ✗ FAIL: 'rule' in help context should use help completer but got: $completer"
    exit 1
fi

# Get completer for 'rule' in context of some other function
__bar_functions+=("other_func")
completer=$(__bar_get_completer "other_func" "rule")
if [[ "$completer" == "__bar_comp_rule_or_function" ]]; then
    echo "  ✓ PASS: 'rule' in other_func context uses rule_or_function completer"
else
    echo "  ✗ FAIL: 'rule' in other_func context should use rule_or_function but got: $completer"
    exit 1
fi

echo ""

# Test 4: Verify cargo module prototypes are also scoped
echo "Test 4: Cargo module prototypes are properly scoped"

if [[ "${__bar_protoregistry[cargo@toolchain]}" == "extcomp cargo" ]]; then
    echo "  ✓ PASS: cargo@toolchain is registered"
else
    echo "  ✗ FAIL: cargo@toolchain should be registered but is: ${__bar_protoregistry[cargo@toolchain]:-NOT SET}"
    exit 1
fi

# Global 'toolchain' should not exist
if [[ -z "${__bar_protoregistry[toolchain]:-}" ]]; then
    echo "  ✓ PASS: Global 'toolchain' is not registered (module-scoped only)"
else
    echo "  ✗ FAIL: Global 'toolchain' should not exist but is: ${__bar_protoregistry[toolchain]}"
    exit 1
fi

echo ""
echo "==================================="
echo "All prototype scoping tests passed!"
echo "==================================="
