#!/bin/bash
# Test cargo completion functions

# shellcheck disable=SC1091
source ../contrib/bar_complete

echo "Testing cargo completion functions..."

# Load the cargo module
if [[ -f ../Bar.d/cargo ]]; then
    source ../Bar.d/cargo
else
    echo "✗ FAIL: Cannot find Bar.d/cargo module"
    exit 1
fi

# Test 1: cargo_tool_complete
echo ""
echo "Test 1: Testing cargo_tool_complete..."
if command -v cargo &>/dev/null; then
    tools=$(cargo_tool_complete)
    tool_count=$(echo "$tools" | wc -l)
    
    if [[ $tool_count -gt 10 ]]; then
        echo "✓ PASS: cargo_tool_complete returned $tool_count tools"
        echo "  Sample tools: $(echo "$tools" | head -5 | tr '\n' ' ')"
    else
        echo "✗ FAIL: Expected more than 10 tools, got $tool_count"
    fi
    
    # Check for common tools
    if echo "$tools" | grep -q "build"; then
        echo "✓ PASS: Found 'build' in tool list"
    else
        echo "✗ FAIL: 'build' not found in tool list"
    fi
else
    echo "ℹ INFO: cargo not installed, skipping cargo_tool_complete test"
fi

# Test 2: cargo_toolchain_complete
echo ""
echo "Test 2: Testing cargo_toolchain_complete..."
if command -v rustup &>/dev/null; then
    toolchains=$(cargo_toolchain_complete)
    
    if [[ -n "$toolchains" ]]; then
        echo "✓ PASS: cargo_toolchain_complete returned toolchains"
        echo "  Toolchains: $toolchains"
        
        # Check that toolchains have + prefix
        if echo "$toolchains" | head -1 | grep -q "^+"; then
            echo "✓ PASS: Toolchains have + prefix"
        else
            echo "✗ FAIL: Toolchains missing + prefix"
        fi
    else
        echo "ℹ INFO: No toolchains installed"
    fi
else
    echo "ℹ INFO: rustup not installed, skipping cargo_toolchain_complete test"
fi

# Test 3: cargo_cargo_complete
echo ""
echo "Test 3: Testing cargo_cargo_complete (black box forwarding)..."
if command -v rustc &>/dev/null; then
    # Test completing cargo subcommands
    completions=$(cargo_cargo_complete "bui")
    
    if echo "$completions" | grep -q "build"; then
        echo "✓ PASS: cargo_cargo_complete finds 'build' from 'bui' prefix"
    else
        echo "ℹ INFO: cargo_cargo_complete fallback mode (no native completion)"
        echo "  Got: $(echo "$completions" | head -3 | tr '\n' ' ')"
    fi
    
    # Test with no prefix
    all_completions=$(cargo_cargo_complete "")
    completion_count=$(echo "$all_completions" | wc -l)
    
    if [[ $completion_count -gt 20 ]]; then
        echo "✓ PASS: cargo_cargo_complete returns many completions ($completion_count)"
        echo "  Sample: $(echo "$all_completions" | head -5 | tr '\n' ' ')"
    else
        echo "ℹ INFO: cargo_cargo_complete using fallback mode"
    fi
else
    echo "ℹ INFO: rustc not installed, skipping cargo_cargo_complete test"
fi

# Test 4: Prototype definitions
echo ""
echo "Test 4: Testing prototype definitions..."
_bar_init_completion_registry

# Parse cargo module
_bar_complete_parse_file --module cargo ../Bar.d/cargo

# Check if toolchain prototype is registered
if [[ -v _bar_complete_protoregistry["cargo@toolchain"] ]]; then
    echo "✓ PASS: toolchain prototype registered for cargo module"
    echo "  Spec: ${_bar_complete_protoregistry[cargo@toolchain]}"
else
    echo "✗ FAIL: toolchain prototype not registered"
fi

# Check if tool prototype is registered
if [[ -v _bar_complete_protoregistry["cargo@tool"] ]]; then
    echo "✓ PASS: tool prototype registered for cargo module"
    echo "  Spec: ${_bar_complete_protoregistry[cargo@tool]}"
else
    echo "✗ FAIL: tool prototype not registered"
fi

# Test 5: Completer expansion
echo ""
echo "Test 5: Testing completer expansion..."
toolchain_completer=$(_bar_get_completer "" "cargo@toolchain")
if [[ "$toolchain_completer" == "_bar_complete_comp_ext cargo_toolchain_complete" ]]; then
    echo "✓ PASS: toolchain completer expands correctly"
else
    echo "✗ FAIL: toolchain completer expansion incorrect"
    echo "  Expected: _bar_complete_comp_ext cargo_toolchain_complete"
    echo "  Got: $toolchain_completer"
fi

tool_completer=$(_bar_get_completer "" "cargo@tool")
if [[ "$tool_completer" == "_bar_complete_comp_ext cargo_tool_complete" ]]; then
    echo "✓ PASS: tool completer expands correctly"
else
    echo "✗ FAIL: tool completer expansion incorrect"
    echo "  Expected: _bar_complete_comp_ext cargo_tool_complete"
    echo "  Got: $tool_completer"
fi

echo ""
echo "Cargo completer tests complete"
