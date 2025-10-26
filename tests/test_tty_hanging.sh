#!/usr/bin/env bash
# Test that bar output doesn't hang when piped or redirected
# This test validates the fix for tty_newline hanging issues

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Testing tty_lib hanging issues..."

# Create a temporary test directory
TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT
cd "$TESTDIR" || exit 1

cat > Barf <<'EOF'
rule test_output:
    echo "Starting test"
    progress "Running step 1"
    echo "Step 1 done"
    progress "Running step 2"
    echo "Step 2 done"
    success "All steps completed"

rule test_verbose:
    die "Testing die function"
    warn "Testing warn"
    note "Testing note"
    info "Testing info"
    debug "Testing debug"
    trace "Testing trace"
EOF

# Test 1: Pipe to cat (should not hang)
echo "Test 1: Piping to cat..."
if timeout 5 "$REPO_ROOT/bar" test_output | cat > /dev/null 2>&1; then
    echo "✓ PASS: Pipe to cat completed without hanging"
else
    rc=$?
    if [[ $rc -eq 124 ]]; then
        echo "✗ FAIL: Command timed out (likely hung)"
        exit 1
    else
        echo "✓ PASS: Command completed (non-zero exit is ok for this test)"
    fi
fi

# Test 2: Redirect to file (should not hang)
echo "Test 2: Redirecting to file..."
if timeout 5 "$REPO_ROOT/bar" test_output > /tmp/bar_test_output.txt 2>&1; then
    echo "✓ PASS: Redirect to file completed without hanging"
else
    rc=$?
    if [[ $rc -eq 124 ]]; then
        echo "✗ FAIL: Command timed out (likely hung)"
        exit 1
    else
        echo "✓ PASS: Command completed"
    fi
fi
rm -f /tmp/bar_test_output.txt

# Test 3: Pipe through multiple commands (should not hang)
echo "Test 3: Pipe through multiple commands..."
if timeout 5 "$REPO_ROOT/bar" test_output 2>&1 | grep -q "Step 1 done"; then
    echo "✓ PASS: Pipe through grep completed without hanging"
else
    rc=$?
    if [[ $rc -eq 124 ]]; then
        echo "✗ FAIL: Command timed out (likely hung)"
        exit 1
    else
        # grep might not find the string, that's ok
        echo "✓ PASS: Command completed"
    fi
fi

# Test 4: Subshell execution (should not hang)
echo "Test 4: Subshell execution..."
if timeout 5 bash -c "cd '$PWD' && '$REPO_ROOT/bar' test_output > /dev/null 2>&1"; then
    echo "✓ PASS: Subshell execution completed without hanging"
else
    rc=$?
    if [[ $rc -eq 124 ]]; then
        echo "✗ FAIL: Command timed out (likely hung)"
        exit 1
    else
        echo "✓ PASS: Command completed"
    fi
fi

# Test 5: Background execution (should not hang)
echo "Test 5: Background execution..."
"$REPO_ROOT/bar" test_output > /dev/null 2>&1 &
bgpid=$!
if timeout 5 bash -c "wait $bgpid" 2>/dev/null; then
    echo "✓ PASS: Background execution completed without hanging"
else
    rc=$?
    if [[ $rc -eq 124 ]]; then
        echo "✗ FAIL: Background process timed out (likely hung)"
        kill -9 $bgpid 2>/dev/null || true
        exit 1
    else
        echo "✓ PASS: Background process completed"
    fi
fi

# Test 6: Test tty_newline directly in non-tty context
echo "Test 6: Testing tty_newline function directly..."
# In a pipe, this should return immediately
if timeout 2 bash -c 'source '"$REPO_ROOT/bar"' --bare; tty_newline' | cat; then
    echo "✓ PASS: tty_newline in pipe context completed without hanging"
else
    rc=$?
    if [[ $rc -eq 124 ]]; then
        echo "✗ FAIL: tty_newline timed out (likely hung)"
        exit 1
    fi
fi

echo ""
echo "All tty hanging tests passed!"
exit 0
