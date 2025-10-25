#!/bin/bash
# Test the Bar.d/notify module

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

echo "=========================================="
echo "Testing Bar.d/notify module"
echo "=========================================="
echo ""

# Test 1: Verify notify function exists and is callable
echo "Test 1: notify function is callable through bar"
output=$(./bar --bare notify "Test message" 2>&1)
exit_code=$?

if [ $exit_code -eq 0 ]; then
    echo "  ✓ PASS: notify exits with code 0 (graceful exit)"
else
    echo "  ✗ FAIL: notify exits with code $exit_code (expected 0)"
    exit 1
fi

# Test 2: Verify warning is shown when notify-send is not available
echo ""
echo "Test 2: Warning is shown when notify-send is not available"
if command -v notify-send >/dev/null 2>&1; then
    echo "  ⊘ SKIP: notify-send is available on this system"
else
    if echo "$output" | grep -q "WARN.*notify-send not available"; then
        echo "  ✓ PASS: Warning message is shown"
    else
        echo "  ✗ FAIL: Warning message not found in output"
        echo "  Output was: $output"
        exit 1
    fi
fi

# Test 3: Verify module can be loaded
echo ""
echo "Test 3: Module loads successfully"
if ./bar --bare --debug notify "Load test" 2>&1 | grep -q "loading.*notify"; then
    echo "  ✓ PASS: Module loaded successfully"
else
    echo "  ✗ FAIL: Module did not load"
    exit 1
fi

echo ""
echo "=========================================="
echo "All notify module tests passed!"
echo "=========================================="
