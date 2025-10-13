#!/bin/bash
# shellcheck disable=SC2317
# SC2317: Functions may appear unreachable to shellcheck but are called dynamically
# Test suite for bar shebang functionality

set -euo pipefail

# Get the absolute path to bar
BAR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAR_EXEC="$BAR_DIR/bar"

# Test counter
TESTS_RUN=0
TESTS_PASSED=0

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

test_assert() {
    local description="$1"
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    
    echo -n "  Test $TESTS_RUN: $description ... "
    
    if "$@"; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}FAIL${NC}"
        return 1
    fi
}

test_assert_output() {
    local description="$1"
    local expected="$2"
    shift 2
    TESTS_RUN=$((TESTS_RUN + 1))
    
    echo -n "  Test $TESTS_RUN: $description ... "
    
    local output
    # Use TERM=dumb to avoid terminal control sequence hangs
    output=$(TERM=dumb "$@" 2>&1)
    
    if [[ "$output" == *"$expected"* ]]; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}FAIL${NC}"
        echo "    Expected: $expected"
        echo "    Got: $output"
        return 1
    fi
}

echo "=== Testing Bar Shebang Functionality ==="
echo

# Test 1: Create an executable Barf file with shebang
echo "Creating test executable Barf file..."
TEST_BARF=$(mktemp /tmp/test_barf_XXXXXX)
chmod +x "$TEST_BARF"

cat > "$TEST_BARF" << 'EOF'
#!/bin/bash
# Placeholder shebang - will be replaced

rule test_rule: -- echo "shebang test executed"

rule MAIN: test_rule
EOF

# Replace the shebang with path to bar
sed -i "1s|.*|#!$BAR_EXEC|" "$TEST_BARF"

echo "Test file created: $TEST_BARF"
echo "Content:"
head -5 "$TEST_BARF"
echo

# Test 2: Execute the file directly
echo "Test Group: Direct Execution"
test_assert_output "Execute Barf file with shebang" "shebang test executed" "$TEST_BARF"

# Test 3: Execute with explicit rule
test_assert_output "Execute Barf file with shebang and rule" "shebang test executed" "$TEST_BARF" test_rule

# Test 4: Verify bar still works normally
echo
echo "Test Group: Normal Bar Execution"

# Create a normal Barf file in a separate temp location
NORMAL_TEST_BARF=$(mktemp /tmp/test_normal_barf_XXXXXX)

cat > "$NORMAL_TEST_BARF" << 'EOF'
#!/bin/bash

rule normal_test: -- echo "normal bar execution"

rule MAIN: normal_test
EOF

# Save current directory and cd to bar directory
ORIGINAL_DIR="$PWD"
cd "$BAR_DIR"

test_assert_output "Normal bar execution with Barf file" "normal bar execution" "$BAR_EXEC" "$NORMAL_TEST_BARF"
test_assert_output "Normal bar execution with explicit rule" "normal bar execution" "$BAR_EXEC" "$NORMAL_TEST_BARF" normal_test

# Test 5: Bar with Barf in current directory
echo
echo "Test Group: Barf in Current Directory"
# Temporarily backup the existing Barf
[[ -f Barf ]] && mv Barf Barf.backup
cat > Barf << 'EOF'
#!/bin/bash

rule current_dir_test: -- echo "current directory bar execution"

rule MAIN: current_dir_test
EOF

test_assert_output "Bar finds Barf in current directory" "current directory bar execution" "$BAR_EXEC"

# Restore original Barf
rm -f Barf
[[ -f Barf.backup ]] && mv Barf.backup Barf

# Return to original directory
cd "$ORIGINAL_DIR"

# Cleanup
rm -f "$NORMAL_TEST_BARF"
rm -f "$TEST_BARF"

echo
echo "==================================="
echo -e "Tests run: $TESTS_RUN"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed: ${RED}$((TESTS_RUN - TESTS_PASSED))${NC}"
echo "==================================="

if [[ $TESTS_PASSED -eq $TESTS_RUN ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
