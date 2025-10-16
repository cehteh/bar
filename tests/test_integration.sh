#!/bin/bash
# Manual integration test for bar_complete

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$SCRIPT_DIR" || exit 1

# shellcheck disable=SC1091
source "$REPO_ROOT/contrib/bar_complete"

test_integration() {
    echo "Testing bar_complete integration..."
    echo "===================================="
    echo

    # Test 1: Initialize and update cache
    echo "Test 1: Initializing cache..."
    _bar_init_completion_registry
    _bar_update_cache "bar"
    echo "✓ Cache initialized"
    echo

    # Test 2: Check if test_barf functions are discovered
    echo "Test 2: Checking discovered functions..."
    if [[ -v _bar_completion_func_params[test_completion_func] ]]; then
        echo "✓ test_completion_func discovered"
        echo "  Parameters: ${_bar_completion_func_params[test_completion_func]}"
    else
        echo "✗ test_completion_func not discovered"
    fi
    echo

    # Test 3: Check if rules are discovered
    echo "Test 3: Checking discovered rules..."
    if [[ -v _bar_completion_rule_params[test_build] ]]; then
        echo "✓ test_build rule discovered"
        echo "  Parameters: ${_bar_completion_rule_params[test_build]}"
    else
        echo "✗ test_build rule not discovered"
    fi
    echo

    # Test 4: Test parameter completion
    echo "Test 4: Testing parameter completion..."
    local result
    result=$(_bar_complete_params "test_completion_func" "test" 2>/dev/null | head -5)
    echo "Completions for 'test_completion_func test*':"
    if [[ -n "$result" ]]; then
        while IFS= read -r line; do
            echo "  $line"
        done <<< "$result"
    else
        echo "  (file completions)"
    fi
    echo

    # Test 5: Test rule completion
    echo "Test 5: Testing rule name completion..."
    result=$(_bar_complete_rule "test" 2>/dev/null)
    echo "Rules starting with 'test':"
    if [[ -n "$result" ]]; then
        while IFS= read -r line; do
            echo "  $line"
        done <<< "$result"
    else
        echo "  (none found)"
    fi
    echo

    # Test 6: Check cargo module completer detection
    echo "Test 6: Checking module-specific completers..."
    if [[ -v _bar_complete_protoregistry["cargo@toolchain"] ]]; then
        echo "✓ cargo@toolchain completer registered"
        echo "  Completer: ${_bar_complete_protoregistry[cargo@toolchain]}"
    else
        echo "ℹ cargo@toolchain completer not found (cargo module not loaded)"
    fi
    echo

    echo "===================================="
    echo "Integration test complete"
}

test_integration

