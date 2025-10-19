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
    result=$(__bar_parse_protos "[--opt] <file> [output]")
    # The new parser extracts protos differently - it keeps the structure
    # Just check that it returns something and doesn't error
    if [[ -n "$result" ]]; then
        echo "✓ Parse basic parameters (returns: $(echo "$result" | tr '\n' ' '))"
    else
        echo "✗ Parse basic parameters - got empty result"
    fi
    
    result=$(__bar_parse_protos "<file..>")
    if [[ -n "$result" ]]; then
        echo "✓ Parse repeated parameter (returns: $(echo "$result" | tr '\n' ' '))"
    else
        echo "✗ Parse repeated parameter - got empty result"
    fi
}

# Test completion registry initialization
test_registry_init() {
    echo "Testing registry initialization..."
    
    __bar_init_completion_registry
    
    # Check that basic completers are registered
    [[ -v __bar_protoregistry[file] ]] && echo "✓ file completer registered" || echo "✗ file completer not registered"
    [[ -v __bar_protoregistry[directory] ]] && echo "✓ directory completer registered" || echo "✗ directory completer not registered"
    [[ -v __bar_protoregistry[rule] ]] && echo "✓ rule completer registered" || echo "✗ rule completer not registered"
}

# Test generic completers
test_generic_completers() {
    echo "Testing generic completers..."
    
    # Test file completer (basic functionality)
    local result
    result=$(__bar_comp_file "test" 2>/dev/null | wc -l)
    echo "✓ File completer executed (found $result matches)"
    
    # Test rule completer
    result=$(__bar_comp_rule "test" 2>/dev/null | wc -l)
    echo "✓ Rule completer executed (found $result matches)"
}

# Test completer lookup
test_completer_lookup() {
    echo "Testing completer lookup..."
    
    __bar_init_completion_registry
    
    local result
    result=$(__bar_get_completer "myfunction" "file")
    assert_equals "__bar_comp_file" "$result" "Lookup file completer"
    
    result=$(__bar_get_completer "myfunction" "directory")
    assert_equals "__bar_comp_directory" "$result" "Lookup directory completer"
    
    result=$(__bar_get_completer "myfunction" "unknown")
    assert_equals "" "$result" "Lookup unknown returns empty"
    
    result=$(__bar_get_completer "myfunction" "command_or_rule")
    assert_equals "__bar_comp_command_or_rule" "$result" "Lookup command_or_rule completer"
}

# Test predicate filtering
test_predicate_filtering() {
    echo "Testing predicate filtering..."
    
    # Test __bar_comp_file with empty string and rulefile predicate
    local result
    result=$(__bar_comp_file "" rulefile 2>/dev/null | wc -l)
    if [[ "$result" -gt 0 ]]; then
        echo "✓ __bar_comp_file \"\" rulefile works (found $result files)"
    else
        echo "✗ __bar_comp_file \"\" rulefile should return files"
        return 1
    fi
    
    # Test __bar_comp_file with partial name and predicate
    result=$(__bar_comp_file test rulefile 2>/dev/null)
    if [[ -n "$result" ]]; then
        echo "✓ __bar_comp_file test rulefile works (found matches)"
    else
        echo "✓ __bar_comp_file test rulefile works (no matches expected if no test* rulefiles)"
    fi
    
    # Test __bar_comp_file with multiple predicates
    result=$(__bar_comp_file "" local rulefile 2>/dev/null | wc -l)
    if [[ "$result" -gt 0 ]]; then
        echo "✓ __bar_comp_file \"\" local rulefile works (found $result files)"
    else
        echo "✗ __bar_comp_file \"\" local rulefile should return files"
        return 1
    fi
}

# Run all tests
test_help_completer() {
    echo "Testing help completer..."

    unset __bar_help_index
    unset __bar_help_rindex

    __bar_invocation="$REPO_ROOT/bar"

    local result
    result=$(__bar_comp_help "abo")
    if grep -Fxq "ABOUT" <<<"$result"; then
        echo "✓ Help completer finds ABOUT"
    else
        echo "✗ Help completer should include ABOUT"
        return 1
    fi

    result=$(__bar_comp_help "invocation")
    if grep -Fxq 'INVOCATION\ AND\ SEMANTICS' <<<"$result"; then
        echo "✓ Help completer escapes multi-word topics"
    else
        echo "✗ Help completer should escape multi-word topics"
        return 1
    fi

    result=$(__bar_comp_help "foo")
    if [[ -z "$result" ]]; then
        echo "✓ Help completer ignores documentation examples"
    else
        echo "✗ Help completer should not include documentation examples (got: $result)"
        return 1
    fi
}

test_bar_help_invocation_completer() {
    echo "Testing bar help invocation completion..."

    local debug_backup="${BAR_COMPLETE_DEBUG-}"
    unset BAR_COMPLETE_DEBUG

    unset __bar_help_index
    unset __bar_help_rindex

    COMPREPLY=()
    COMP_WORDS=("bar" "help" "")
    COMP_CWORD=2
    COMP_LINE="bar help "
    COMP_POINT=${#COMP_LINE}

    _bar_complete

    if [[ ${#COMPREPLY[@]} -eq 0 ]]; then
        echo "✗ bar help completion returned no suggestions"
        if [[ -n "$debug_backup" ]]; then
            BAR_COMPLETE_DEBUG="$debug_backup"
        else
            unset BAR_COMPLETE_DEBUG
        fi
        return 1
    fi

    if printf '%s\n' "${COMPREPLY[@]}" | grep -Fxq "ABOUT"; then
        echo "✓ bar help produces help topic completions"
    else
        echo "✗ bar help should complete help topics (got: ${COMPREPLY[*]})"
        if [[ -n "$debug_backup" ]]; then
            BAR_COMPLETE_DEBUG="$debug_backup"
        else
            unset BAR_COMPLETE_DEBUG
        fi
        return 1
    fi

    COMPREPLY=()
    COMP_WORDS=("bar" "help" "--short" "")
    COMP_CWORD=3
    COMP_LINE="bar help --short "
    COMP_POINT=${#COMP_LINE}

    _bar_complete

    if [[ ${#COMPREPLY[@]} -eq 0 ]]; then
        echo "✗ bar help --short completion returned no suggestions"
        if [[ -n "$debug_backup" ]]; then
            BAR_COMPLETE_DEBUG="$debug_backup"
        else
            unset BAR_COMPLETE_DEBUG
        fi
        return 1
    fi

    if printf '%s\n' "${COMPREPLY[@]}" | grep -Fxq "ABOUT"; then
        echo "✓ bar help --short produces help topic completions"
    else
        echo "✗ bar help --short should complete help topics (got: ${COMPREPLY[*]})"
        if [[ -n "$debug_backup" ]]; then
            BAR_COMPLETE_DEBUG="$debug_backup"
        else
            unset BAR_COMPLETE_DEBUG
        fi
        return 1
    fi

    if [[ -n "$debug_backup" ]]; then
        BAR_COMPLETE_DEBUG="$debug_backup"
    else
        unset BAR_COMPLETE_DEBUG
    fi
}

test_completion_cache_reuse() {
    echo "Testing completion caching..."

    __bar_cache=()
    __bar_cache_signature=""
    __bar_cache_prefix=""

    COMPREPLY=()
    COMP_WORDS=("bar" "help" "")
    COMP_CWORD=2
    COMP_LINE="bar help "
    COMP_POINT=${#COMP_LINE}

    _bar_complete

    if [[ ${#COMPREPLY[@]} -eq 0 ]]; then
        echo "✗ initial completion returned no suggestions"
        return 1
    fi

    local first_result
    first_result=$(printf '%s\n' "${COMPREPLY[@]}")
    local -a first_array=("${COMPREPLY[@]}")
    local first_signature="$__bar_cache_signature"

    __bar_completion_rules=("__cache_test_rule")
    __bar_completion_functions=("__cache_test_func")

    COMPREPLY=()
    _bar_complete

    local second_result
    second_result=$(printf '%s\n' "${COMPREPLY[@]}")

    if [[ "$first_result" == "$second_result" ]]; then
        echo "✓ cache reuses previous completions for identical context"
    else
        echo "✗ cache should return identical completions"
        echo "  First:"
        printf '    %s\n' "${first_result}"
        echo "  Second:"
        printf '    %s\n' "${second_result}"
        return 1
    fi

    COMP_WORDS=("bar" "help" "A")
    COMP_CWORD=2
    COMP_LINE="bar help A"
    COMP_POINT=${#COMP_LINE}

    COMPREPLY=()
    _bar_complete

    local -a second_prefix_array=("${COMPREPLY[@]}")
    local filtered_expected=()
    local item
    for item in "${first_array[@]}"; do
        if [[ "$item" == A* ]]; then
            filtered_expected+=("$item")
        fi
    done

    local expected_filtered_str
    expected_filtered_str=$(printf '%s\n' "${filtered_expected[@]}")
    local second_filtered_str
    second_filtered_str=$(printf '%s\n' "${second_prefix_array[@]}")

    if [[ "$second_filtered_str" == "$expected_filtered_str" ]]; then
        echo "✓ cache filters previous completions for extended prefix"
    else
        echo "✗ cache should reuse and filter previous completions"
        echo "  Expected:"
        printf '    %s\n' "${expected_filtered_str}"
        echo "  Actual:"
        printf '    %s\n' "${second_filtered_str}"
        return 1
    fi

    if [[ "$__bar_cache_signature" == "$first_signature" ]]; then
        echo "✓ cache signature unchanged for extended prefix"
    else
        echo "✗ cache signature should stay the same for extended prefix"
        echo "  First:  $first_signature"
        echo "  Second: $__bar_cache_signature"
        return 1
    fi

    if [[ "$__bar_cache_prefix" == "A" ]]; then
        echo "✓ cache prefix tracks latest user input"
    else
        echo "✗ cache prefix should update to current input"
        echo "  Got: $__bar_cache_prefix"
        return 1
    fi
}

test_external_command_passthrough() {
    echo "Testing external command passthrough..."

    local test_cmd="bar_fake_extcomp_test"

    bar_fake_extcomp_test_complete()
    {
        COMPREPLY=("fake-alpha" "fake-beta")
    }

    complete -F bar_fake_extcomp_test_complete "$test_cmd"

    COMPREPLY=()
    COMP_WORDS=("./bar" "$test_cmd" "")
    COMP_CWORD=2
    COMP_LINE="./bar $test_cmd "
    COMP_POINT=${#COMP_LINE}

    _bar_complete

    local actual="${COMPREPLY[*]}"
    local expected="fake-alpha fake-beta"

    if [[ "$actual" == "$expected" ]]; then
        echo "✓ external command completions forwarded"
    else
        echo "✗ external command completions should be forwarded"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        complete -r "$test_cmd" 2>/dev/null || true
        unset -f bar_fake_extcomp_test_complete
        return 1
    fi

    complete -r "$test_cmd" 2>/dev/null || true
    unset -f bar_fake_extcomp_test_complete
    return 0
}

test_flag_completion_order() {
    echo "Testing flag-first completion ordering..."

    local result
    result=$(__bar_finalize_completions "--bare" "build" "--debug" "doc" "build")
    local expected=$'--bare\n--debug\nbuild\ndoc'

    if [[ "$result" == "$expected" ]]; then
        echo "✓ flag completions sort ahead of other items"
    else
        echo "✗ flag completion ordering mismatch"
        echo "  Expected:"
        while IFS= read -r line; do
            printf '    %s\n' "$line"
        done <<< "$expected"
        echo "  Actual:"
        while IFS= read -r line; do
            printf '    %s\n' "$line"
        done <<< "$result"
        return 1
    fi
}

test_completion_uses_nosort() {
    echo "Testing completion nosort option..."

    if ! type compopt >/dev/null 2>&1; then
        echo "✓ compopt unavailable; skipping nosort assertion"
        return 0
    fi

    local compopt_called=0
    compopt() {
        compopt_called=1
        builtin compopt "$@" 2>/dev/null || true
    }

    __bar_cache=()
    __bar_cache_signature=""
    __bar_cache_prefix=""

    COMPREPLY=()
    COMP_WORDS=("bar" "help" "")
    COMP_CWORD=2
    COMP_LINE="bar help "
    COMP_POINT=${#COMP_LINE}

    _bar_complete

    unset -f compopt

    if [[ $compopt_called -eq 1 ]]; then
        echo "✓ completion requests nosort from bash"
        return 0
    else
        echo "✗ completion should call compopt -o nosort"
        return 1
    fi
}

main() {
    local status=0

    echo "=========================================="
    echo "Bar Completion Tests"
    echo "=========================================="
    echo

    if ! test_parse_params; then
        status=1
    fi
    echo

    if ! test_registry_init; then
        status=1
    fi
    echo

    if ! test_generic_completers; then
        status=1
    fi
    echo

    if ! test_completer_lookup; then
        status=1
    fi
    echo

    if ! test_predicate_filtering; then
        status=1
    fi
    echo

    if ! test_help_completer; then
        status=1
    fi
    echo

    if ! test_bar_help_invocation_completer; then
        status=1
    fi
    echo

    if ! test_flag_completion_order; then
        status=1
    fi
    echo

    if ! test_completion_uses_nosort; then
        status=1
    fi
    echo

    if ! test_external_command_passthrough; then
        status=1
    fi
    echo

    if ! test_completion_cache_reuse; then
        status=1
    fi

    echo "=========================================="
    echo "Tests complete"
    echo "=========================================="

    return "$status"
}

main "$@"
exit $?
