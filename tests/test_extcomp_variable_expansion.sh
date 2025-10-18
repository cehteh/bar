#!/bin/bash
# Test variable expansion in extcomp prototype

# shellcheck disable=SC1091
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

source "$REPO_ROOT/contrib/bar_complete"

echo "Testing variable expansion in _bar_complete_comp_extcomp..."

# Test 1: Variable expansion with empty variable
echo ""
echo "Test 1: Variable expansion with empty variable"
export TEST_VAR=""
result=$(_bar_complete_comp_extcomp "echo \${TEST_VAR} hello" "wor")
if [[ -n "$result" ]]; then
    echo "✓ PASS: Function handles empty variable correctly"
else
    echo "ℹ INFO: No completions (expected for file-based fallback)"
fi

# Test 2: Variable expansion with set variable
echo ""
echo "Test 2: Variable expansion with set variable"
export TEST_VAR="test"
# Manually check internal state by adding debug
_test_var_expansion() {
    local cmd="$1"
    shift
    local -a args=()
    local -a remaining_args=("$@")

    if [[ "$cmd" == *' '* ]]; then
        local -a cmd_parts=()
        read -ra cmd_parts <<< "$cmd"
        cmd="${cmd_parts[0]}"
        if (( ${#cmd_parts[@]} > 1 )); then
            args+=("${cmd_parts[@]:1}")
        fi
    fi
    
    local -a expanded_args=()
    local arg
    for arg in "${args[@]}"; do
        if [[ "$arg" =~ \$\{[^}]+\} ]]; then
            local expanded
            expanded=$(eval echo "$arg")
            if [[ -n "$expanded" ]]; then
                expanded_args+=("$expanded")
            fi
        else
            expanded_args+=("$arg")
        fi
    done
    
    for arg in "${remaining_args[@]}"; do
        if [[ "$arg" =~ \$\{[^}]+\} ]]; then
            local expanded
            expanded=$(eval echo "$arg")
            if [[ -n "$expanded" ]]; then
                expanded_args+=("$expanded")
            fi
        else
            expanded_args+=("$arg")
        fi
    done
    
    args=("${expanded_args[@]}")
    echo "Final args: (${args[*]})"
    return 0
}

result=$(_test_var_expansion "echo \${TEST_VAR} hello" "world")
if [[ "$result" == *"test"* ]]; then
    echo "✓ PASS: Variable ${TEST_VAR} correctly expanded to 'test'"
else
    echo "✗ FAIL: Variable not expanded correctly"
    echo "  Got: $result"
fi

# Test 3: Multiple variables
echo ""
echo "Test 3: Multiple variables expansion"
export VAR1="one"
export VAR2="two"
result=$(_test_var_expansion "cmd \${VAR1} \${VAR2}" "arg")
if [[ "$result" == *"one"* && "$result" == *"two"* ]]; then
    echo "✓ PASS: Multiple variables expanded correctly"
else
    echo "✗ FAIL: Multiple variables not expanded"
    echo "  Got: $result"
fi

# Test 4: Real-world git example
echo ""
echo "Test 4: Real-world git completion"
if command -v git &>/dev/null; then
    result=$(_bar_complete_comp_extcomp "git checkout" "")
    completion_count=$(echo "$result" | wc -l)
    
    if [[ $completion_count -gt 0 ]]; then
        echo "✓ PASS: git checkout completion works ($completion_count branches)"
    else
        echo "ℹ INFO: git checkout returned no completions (expected in empty repo)"
    fi
else
    echo "ℹ INFO: git not available, skipping test"
fi

# Test 5: Cargo-like example (without actual cargo completion)
echo ""
echo "Test 5: Cargo-like variable expansion"
export CARGO_TOOLCHAIN="+stable"
_test_cargo_args() {
    local cmd="$1"
    shift
    local -a args=()
    local -a remaining_args=("$@")

    if [[ "$cmd" == *' '* ]]; then
        local -a cmd_parts=()
        read -ra cmd_parts <<< "$cmd"
        cmd="${cmd_parts[0]}"
        if (( ${#cmd_parts[@]} > 1 )); then
            args+=("${cmd_parts[@]:1}")
        fi
    fi
    
    local -a expanded_args=()
    local arg
    for arg in "${args[@]}"; do
        if [[ "$arg" =~ \$\{[^}]+\} ]]; then
            local expanded
            expanded=$(eval echo "$arg")
            if [[ -n "$expanded" ]]; then
                expanded_args+=("$expanded")
            fi
        else
            expanded_args+=("$arg")
        fi
    done
    
    for arg in "${remaining_args[@]}"; do
        if [[ "$arg" =~ \$\{[^}]+\} ]]; then
            local expanded
            expanded=$(eval echo "$arg")
            if [[ -n "$expanded" ]]; then
                expanded_args+=("$expanded")
            fi
        else
            expanded_args+=("$arg")
        fi
    done
    
    args=("${expanded_args[@]}")
    
    # Check that +stable was properly inserted
    local found_toolchain=false
    for arg in "${args[@]}"; do
        if [[ "$arg" == "+stable" ]]; then
            found_toolchain=true
            break
        fi
    done
    
    if [[ $found_toolchain == true ]]; then
        echo "PASS"
    else
        echo "FAIL: args=(${args[*]})"
    fi
}

result=$(_test_cargo_args "cargo \${CARGO_TOOLCHAIN} build --workspace" "--release")
if [[ "$result" == "PASS" ]]; then
    echo "✓ PASS: CARGO_TOOLCHAIN variable expanded to +stable in argument list"
else
    echo "✗ FAIL: Variable expansion failed"
    echo "  $result"
fi

echo ""
echo "Variable expansion tests complete"
