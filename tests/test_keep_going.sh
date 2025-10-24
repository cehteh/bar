#!/usr/bin/env bash
# Test keep-going functionality

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Create a test Barf file for keep-going tests
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

cd "$TEST_DIR"
mkdir -p Bar.d  # Create Bar.d so bar recognizes this as the toplevel
# Symlink necessary Bar.d modules
ln -s "$REPO_ROOT/Bar.d/std_lib" Bar.d/std_lib
ln -s "$REPO_ROOT/Bar.d/rule_lib" Bar.d/rule_lib
ln -s "$REPO_ROOT/Bar.d/tty_lib" Bar.d/tty_lib
# Create dummy _rules file to satisfy glob expansion
touch Bar.d/dummy_rules

# Test 1: Keep-going disabled (default) - stops at first failure
test_keep_going_disabled() {
    echo "Test 1: Keep-going disabled (default)"
    
    cat > Barf <<'EOF'
rule test1: --pure -- 'echo "Task 1"; true'
rule test1: --pure -- 'echo "Task 2"; false'
rule test1: --pure -- 'echo "Task 3"; true'
EOF
    
    local output
    if output=$("$REPO_ROOT/bar" --bare test1 2>&1); then
        echo "ERROR: test1 should have failed"
        return 1
    fi
    
    # Should only see task1 and task2 (stops at task2 failure)
    if ! echo "$output" | grep -q "Task 1"; then
        echo "ERROR: Task 1 should have executed"
        return 1
    fi
    if ! echo "$output" | grep -q "Task 2"; then
        echo "ERROR: Task 2 should have executed"
        return 1
    fi
    if echo "$output" | grep -q "Task 3"; then
        echo "ERROR: Task 3 should NOT have executed (stopped at failure)"
        return 1
    fi
    
    echo "✓ Keep-going disabled works correctly"
    rm Barf
}

# Test 2: Keep-going enabled - continues through pure failures
test_keep_going_enabled() {
    echo "Test 2: Keep-going enabled with pure clauses"
    
    cat > Barf <<'EOF'
rule test2: --pure -- 'echo "Task 1"; true'
rule test2: --pure -- 'echo "Task 2"; false'
rule test2: --pure -- 'echo "Task 3"; true'
EOF
    
    local output
    if output=$(BAR_KEEP_GOING=yes "$REPO_ROOT/bar" --bare test2 2>&1); then
        echo "ERROR: test2 should have failed (keep-going propagates failure)"
        return 1
    fi
    
    # All three tasks should execute
    if ! echo "$output" | grep -q "Task 1"; then
        echo "ERROR: Task 1 should have executed"
        return 1
    fi
    if ! echo "$output" | grep -q "Task 2"; then
        echo "ERROR: Task 2 should have executed"
        return 1
    fi
    if ! echo "$output" | grep -q "Task 3"; then
        echo "ERROR: Task 3 should have executed (keep-going)"
        return 1
    fi
    
    echo "✓ Keep-going enabled works correctly"
    rm Barf
}

# Test 3: Non-pure clause stops keep-going
test_nonpure_stops_keepgoing() {
    echo "Test 3: Non-pure clause halts keep-going"
    
    cat > Barf <<'EOF'
rule test3: --pure -- 'echo "Task 1"; true'
rule test3: --pure -- 'echo "Task 2"; false'
rule test3: -- 'echo "Task 3"; true'
EOF
    
    local output
    if output=$(BAR_KEEP_GOING=yes "$REPO_ROOT/bar" --bare test3 2>&1); then
        echo "ERROR: test3 should have failed"
        return 1
    fi
    
    # Tasks 1 and 2 execute, but 3 does not (non-pure)
    if ! echo "$output" | grep -q "Task 1"; then
        echo "ERROR: Task 1 should have executed"
        return 1
    fi
    if ! echo "$output" | grep -q "Task 2"; then
        echo "ERROR: Task 2 should have executed"
        return 1
    fi
    if echo "$output" | grep -q "Task 3"; then
        echo "ERROR: Task 3 should NOT have executed (non-pure stops keep-going)"
        return 1
    fi
    
    echo "✓ Non-pure clause stops keep-going correctly"
    rm Barf
}

# Test 4: --conclusive takes precedence over keep-going
test_conclusive_precedence() {
    echo "Test 4: --conclusive takes precedence"
    
    cat > Barf <<'EOF'
rule test4: --pure -- 'echo "Task 1"; true'
rule test4: --pure --conclusive -- 'echo "Task 2"; false'
rule test4: --pure -- 'echo "Task 3"; true'
EOF
    
    local output
    if output=$(BAR_KEEP_GOING=yes "$REPO_ROOT/bar" --bare test4 2>&1); then
        echo "ERROR: test4 should have failed"
        return 1
    fi
    
    # Tasks 1 and 2 execute, but 3 does not (conclusive)
    if ! echo "$output" | grep -q "Task 1"; then
        echo "ERROR: Task 1 should have executed"
        return 1
    fi
    if ! echo "$output" | grep -q "Task 2"; then
        echo "ERROR: Task 2 should have executed"
        return 1
    fi
    if echo "$output" | grep -q "Task 3"; then
        echo "ERROR: Task 3 should NOT have executed (conclusive failure)"
        return 1
    fi
    
    echo "✓ --conclusive precedence works correctly"
    rm Barf
}

# Test 5: Mixed scenario - realistic use case
test_mixed_realistic() {
    echo "Test 5: Mixed realistic scenario"
    
    cat > Barf <<'EOF'
rule test5: --pure -- 'echo "A"; true'
rule test5: --pure -- 'echo "B"; false'
rule test5: --pure -- 'echo "C"; true'
rule test5: --pure -- 'echo "D"; false'
rule test5: --pure -- 'echo "E"; true'
EOF
    
    local output
    if output=$(BAR_KEEP_GOING=yes "$REPO_ROOT/bar" --bare test5 2>&1); then
        echo "ERROR: test5 should have failed"
        return 1
    fi
    
    # All tasks should execute
    for task in A B C D E; do
        if ! echo "$output" | grep -q "$task"; then
            echo "ERROR: Task $task should have executed"
            echo "Output: $output"
            return 1
        fi
    done
    
    echo "✓ Mixed realistic scenario works correctly"
    rm Barf
}

# Run all tests
main() {
    echo "=== Testing Keep-Going Functionality ==="
    echo
    
    test_keep_going_disabled
    echo
    
    test_keep_going_enabled
    echo
    
    test_nonpure_stops_keepgoing
    echo
    
    test_conclusive_precedence
    echo
    
    test_mixed_realistic
    echo
    
    echo "=== All Keep-Going Tests Passed ==="
}

main "$@"
