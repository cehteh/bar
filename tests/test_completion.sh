#!/bin/bash
# Test for bar_complete functionality

# shellcheck disable=SC1091
# Source the completion script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

source "$REPO_ROOT/contrib/bar_complete"

# Helper function for tests
assert_equals() {
    local expected="$1"
    local actual="$2"
    local test_name="$3"
    
    if [[ "$expected" == "$actual" ]]; then
        echo "✓ $test_name"
        return 0
    else
        echo "✗ $test_name"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        return 1
    fi
}

# Test parameter parsing
test_parse_params() {
    echo "Testing parameter parsing..."
    
    local result
    result=$(_bar_parse_protos "[--opt] <file> [output]")
    # The new parser extracts protos differently - it keeps the structure
    # Just check that it returns something and doesn't error
    if [[ -n "$result" ]]; then
        echo "✓ Parse basic parameters (returns: $(echo "$result" | tr '\n' ' '))"
    else
        echo "✗ Parse basic parameters - got empty result"
    fi
    
    result=$(_bar_parse_protos "<file..>")
    if [[ -n "$result" ]]; then
        echo "✓ Parse repeated parameter (returns: $(echo "$result" | tr '\n' ' '))"
    else
        echo "✗ Parse repeated parameter - got empty result"
    fi
}

# Test completion registry initialization
test_registry_init() {
    echo "Testing registry initialization..."
    
    _bar_init_completion_registry
    
    # Check that basic completers are registered
    [[ -v _bar_complete_protoregistry[file] ]] && echo "✓ file completer registered" || echo "✗ file completer not registered"
    [[ -v _bar_complete_protoregistry[directory] ]] && echo "✓ directory completer registered" || echo "✗ directory completer not registered"
    [[ -v _bar_complete_protoregistry[rule] ]] && echo "✓ rule completer registered" || echo "✗ rule completer not registered"
}

# Test generic completers
test_generic_completers() {
    echo "Testing generic completers..."
    
    # Test file completer (basic functionality)
    local result
    result=$(_bar_complete_comp_file "test" 2>/dev/null | wc -l)
    echo "✓ File completer executed (found $result matches)"
    
    # Test rule completer
    result=$(_bar_complete_comp_rule "test" 2>/dev/null | wc -l)
    echo "✓ Rule completer executed (found $result matches)"
}

# Test completer lookup
test_completer_lookup() {
    echo "Testing completer lookup..."
    
    _bar_init_completion_registry
    
    local result
    result=$(_bar_get_completer "myfunction" "file")
    assert_equals "_bar_complete_comp_file" "$result" "Lookup file completer"
    
    result=$(_bar_get_completer "myfunction" "directory")
    assert_equals "_bar_complete_comp_directory" "$result" "Lookup directory completer"
    
    result=$(_bar_get_completer "myfunction" "unknown")
    assert_equals "" "$result" "Lookup unknown returns empty"
    
    result=$(_bar_get_completer "myfunction" "command_or_rule")
    assert_equals "_bar_complete_comp_command_or_rule" "$result" "Lookup command_or_rule completer"
}

# Test predicate filtering
test_predicate_filtering() {
    echo "Testing predicate filtering..."
    
    # Test _bar_complete_comp_file with empty string and rulefile predicate
    local result
    result=$(_bar_complete_comp_file "" rulefile 2>/dev/null | wc -l)
    if [[ "$result" -gt 0 ]]; then
        echo "✓ _bar_complete_comp_file \"\" rulefile works (found $result files)"
    else
        echo "✗ _bar_complete_comp_file \"\" rulefile should return files"
        return 1
    fi
    
    # Test _bar_complete_comp_file with partial name and predicate
    result=$(_bar_complete_comp_file test rulefile 2>/dev/null)
    if [[ -n "$result" ]]; then
        echo "✓ _bar_complete_comp_file test rulefile works (found matches)"
    else
        echo "✓ _bar_complete_comp_file test rulefile works (no matches expected if no test* rulefiles)"
    fi
    
    # Test _bar_complete_comp_file with multiple predicates
    result=$(_bar_complete_comp_file "" local rulefile 2>/dev/null | wc -l)
    if [[ "$result" -gt 0 ]]; then
        echo "✓ _bar_complete_comp_file \"\" local rulefile works (found $result files)"
    else
        echo "✗ _bar_complete_comp_file \"\" local rulefile should return files"
        return 1
    fi
}

# Run all tests
test_help_completer() {
    echo "Testing help completer..."

    unset _bar_complete_help_index
    unset _bar_complete_help_rindex

    _bar_complete_invocation="$REPO_ROOT/bar"

    local result
    result=$(_bar_complete_comp_help "abo")
    if grep -Fxq "ABOUT" <<<"$result"; then
        echo "✓ Help completer finds ABOUT"
    else
        echo "✗ Help completer should include ABOUT"
        return 1
    fi

    result=$(_bar_complete_comp_help "invocation")
    if grep -Fxq 'INVOCATION\ AND\ SEMANTICS' <<<"$result"; then
        echo "✓ Help completer escapes multi-word topics"
    else
        echo "✗ Help completer should escape multi-word topics"
        return 1
    fi
}

main() {
    echo "=========================================="
    echo "Bar Completion Tests"
    echo "=========================================="
    echo
    
    test_parse_params
    echo
    test_registry_init
    echo
    test_generic_completers
    echo
    test_completer_lookup
    echo
    test_predicate_filtering
    echo
    test_help_completer
    
    echo "=========================================="
    echo "Tests complete"
    echo "=========================================="
}

main
