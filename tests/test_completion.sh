#!/bin/bash
# Test for bar_complete functionality

# shellcheck disable=SC1091
# Source the completion script
source ../contrib/bar_complete

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
    result=$(_bar_parse_params "[--opt] <file> [output]")
    local expected=$'--opt\nfile\noutput'
    assert_equals "$expected" "$result" "Parse basic parameters"
    
    result=$(_bar_parse_params "<file..>")
    expected="file"
    assert_equals "$expected" "$result" "Parse repeated parameter"
}

# Test completion registry initialization
test_registry_init() {
    echo "Testing registry initialization..."
    
    _bar_init_completion_registry
    
    # Check that basic completers are registered
    [[ -v _bar_completion_registry[file] ]] && echo "✓ file completer registered" || echo "✗ file completer not registered"
    [[ -v _bar_completion_registry[directory] ]] && echo "✓ directory completer registered" || echo "✗ directory completer not registered"
    [[ -v _bar_completion_registry[rule] ]] && echo "✓ rule completer registered" || echo "✗ rule completer not registered"
}

# Test generic completers
test_generic_completers() {
    echo "Testing generic completers..."
    
    # Test file completer (basic functionality)
    local result
    result=$(_bar_complete_file "test" 2>/dev/null | wc -l)
    echo "✓ File completer executed (found $result matches)"
    
    # Test rule completer
    result=$(_bar_complete_rule "test" 2>/dev/null | wc -l)
    echo "✓ Rule completer executed (found $result matches)"
}

# Test completer lookup
test_completer_lookup() {
    echo "Testing completer lookup..."
    
    _bar_init_completion_registry
    
    local result
    result=$(_bar_get_completer "myfunction" "file")
    assert_equals "_bar_complete_file" "$result" "Lookup file completer"
    
    result=$(_bar_get_completer "myfunction" "directory")
    assert_equals "_bar_complete_directory" "$result" "Lookup directory completer"
    
    result=$(_bar_get_completer "myfunction" "unknown")
    assert_equals "" "$result" "Lookup unknown returns empty"
    
    result=$(_bar_get_completer "myfunction" "command_or_rule")
    assert_equals "_bar_complete_command_or_rule" "$result" "Lookup command_or_rule completer"
}

# Run all tests
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
    
    echo "=========================================="
    echo "Tests complete"
    echo "=========================================="
}

main
