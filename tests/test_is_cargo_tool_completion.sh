#!/bin/bash

# Test completion for is_cargo_tool_installed
#
# This test verifies that:
# 1. Functions with literal punctuation in params (like [+toolchain]) are properly tracked
# 2. The literal prefix "+" is extracted correctly  
# 3. Prototypes are registered and can be looked up

cd "$(dirname "$0")/.." || exit 1

echo "=== Test 1: Source completion and parse cargo module ==="
source contrib/bar_complete
_bar_complete_parse_file Bar.d/cargo
echo "✓ Completion script sourced and cargo module parsed"

echo ""
echo "=== Test 2: Verify function is tracked ==="
if [[ " ${_bar_completion_functions[*]} " == *" is_cargo_tool_installed "* ]]; then
    echo "✓ is_cargo_tool_installed is tracked"
else
    echo "✗ is_cargo_tool_installed is NOT tracked"
    exit 1
fi

echo ""
echo "=== Test 3: Verify params are stored correctly ==="
params="${_bar_completion_func_params[is_cargo_tool_installed]}"
expected="[+toolchain] <tool> [args..]"
if [[ "$params" == "$expected" ]]; then
    echo "✓ Params stored correctly: '$params'"
else
    echo "✗ Params incorrect. Expected: '$expected', Got: '$params'"
    exit 1
fi

echo ""
echo "=== Test 4: Verify prototypes are registered for cargo module ==="
if [[ -v _bar_complete_protoregistry[cargo@toolchain] ]]; then
    echo "✓ cargo@toolchain prototype registered: ${_bar_complete_protoregistry[cargo@toolchain]}"
else
    echo "✗ cargo@toolchain prototype NOT registered"
    exit 1
fi

if [[ -v _bar_complete_protoregistry[cargo@tool] ]]; then
    echo "✓ cargo@tool prototype registered: ${_bar_complete_protoregistry[cargo@tool]}"
else
    echo "✗ cargo@tool prototype NOT registered"
    exit 1
fi

echo ""
echo "=== Test 5: Verify module tracking ==="
if [[ "${_bar_completion_func_module[is_cargo_tool_installed]}" == "cargo" ]]; then
    echo "✓ Module tracked correctly: cargo"
else
    echo "✗ Module not tracked. Got: '${_bar_completion_func_module[is_cargo_tool_installed]}'"
    exit 1
fi

echo ""
echo "=== Test 6: Verify literal punctuation extraction ==="
mapfile -t punct_parts < <(_bar_extract_literal_punct "+toolchain")
proto_clean="${punct_parts[0]}"
literal_prefix="${punct_parts[1]}"
literal_suffix="${punct_parts[2]}"

if [[ "$proto_clean" == "toolchain" && "$literal_prefix" == "+" && "$literal_suffix" == "" ]]; then
    echo "✓ Literal punctuation extracted correctly"
    echo "  Clean proto: '$proto_clean'"
    echo "  Literal prefix: '$literal_prefix'"
else
    echo "✗ Literal punctuation extraction failed"
    echo "  Clean proto: '$proto_clean' (expected 'toolchain')"
    echo "  Literal prefix: '$literal_prefix' (expected '+')"
    exit 1
fi

echo ""
echo "=== Test 7: Verify completer lookup ==="
completer=$(_bar_get_completer "is_cargo_tool_installed" "toolchain")
expected_completer="_bar_complete_comp_extcomp cargo"
if [[ "$completer" == "$expected_completer" ]]; then
    echo "✓ Completer lookup successful: '$completer'"
else
    echo "✗ Completer lookup failed. Expected: '$expected_completer', Got: '$completer'"
    exit 1
fi

echo ""
echo "=== Test 8: Verify end-to-end completion ==="
# Stub the external completer so we do not depend on cargo's native completion results.
_bar_complete_comp_extcomp()
{
    local command_name="$1"
    local cur="$2"

    if [[ "$command_name" == "cargo" ]]; then
        for item in +stable +nightly; do
            if [[ -z "$cur" || "$item" == "$cur"* ]]; then
                echo "$item"
            fi
        done
        return 0
    fi

    return 1
}

COMP_WORDS=("./bar" "is_cargo_toolchain_available" "")
COMP_CWORD=2
COMPREPLY=()
_bar_complete

if [[ " ${COMPREPLY[*]} " == *" +stable "* && " ${COMPREPLY[*]} " == *" +nightly "* ]]; then
    echo "✓ Completion returns toolchains via _bar_complete"
else
    echo "✗ Completion did not return expected toolchains"
    echo "  Got: ${COMPREPLY[*]}"
    exit 1
fi

echo ""
echo "=== All structural tests passed! ==="
echo ""
echo "Note: To test actual completion behavior interactively:"
echo "  1. Source contrib/bar_complete in your bash shell"
echo "  2. Enable bash completion for bar"
echo "  3. Try: bar is_cargo_tool_installed <TAB>"
echo "  4. You should see toolchain options like +stable, +nightly, etc."
echo "  5. After selecting a toolchain, <TAB> again should show cargo tools"
