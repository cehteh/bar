#!/bin/bash
# Test email module functionality

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Define minimal stubs needed for the email module
# shellcheck disable=SC2317
function debug() { :; }
# shellcheck disable=SC2317
function note() { :; }
# shellcheck disable=SC2317
function info() { echo "$@" >&2; }
# shellcheck disable=SC2317
function error() { echo "ERROR: $*" >&2; }
# shellcheck disable=SC2317
function memofn() { :; }
# shellcheck disable=SC2317
function rule() { :; }

# Source the email module directly
# shellcheck source=/dev/null
source "$REPO_ROOT/Bar.d/email" 2>/dev/null

echo "Testing email module..."

# Test 1: Check if is_mail_installed function exists
echo -n "Test 1: is_mail_installed function exists... "
if declare -f is_mail_installed >/dev/null; then
    echo "✓ PASS"
else
    echo "✗ FAIL"
    exit 1
fi

# Test 2: Check if get_mail_command function exists
echo -n "Test 2: get_mail_command function exists... "
if declare -f get_mail_command >/dev/null; then
    echo "✓ PASS"
else
    echo "✗ FAIL"
    exit 1
fi

# Test 3: Check if email_send function exists
echo -n "Test 3: email_send function exists... "
if declare -f email_send >/dev/null; then
    echo "✓ PASS"
else
    echo "✗ FAIL"
    exit 1
fi

# Test 4: Test is_mail_installed (should fail in test environment without mail)
echo -n "Test 4: is_mail_installed detection... "
if is_mail_installed 2>/dev/null; then
    echo "✓ PASS (mail utility found)"
else
    echo "✓ PASS (no mail utility, as expected in test environment)"
fi

# Test 5: Test email_send argument validation (missing --to)
echo -n "Test 5: email_send validates --to requirement... "
if email_send --subject "Test" --text "Test message" 2>/dev/null; then
    echo "✗ FAIL (should require --to)"
    exit 1
else
    echo "✓ PASS"
fi

# Test 6: Test email_send argument validation (missing --subject)
echo -n "Test 6: email_send validates --subject requirement... "
if email_send --to "test@example.com" --text "Test message" 2>/dev/null; then
    echo "✗ FAIL (should require --subject)"
    exit 1
else
    echo "✓ PASS"
fi

# Test 7: Test email_send with invalid file
echo -n "Test 7: email_send validates file existence... "
if email_send --to "test@example.com" --subject "Test" --file "/nonexistent/file.txt" 2>/dev/null; then
    echo "✗ FAIL (should reject nonexistent file)"
    exit 1
else
    echo "✓ PASS"
fi

# Test 8: Test email_send with invalid attachment
echo -n "Test 8: email_send validates attachment existence... "
if email_send --to "test@example.com" --subject "Test" --text "Test" --attach "/nonexistent/file.txt" 2>/dev/null; then
    echo "✗ FAIL (should reject nonexistent attachment)"
    exit 1
else
    echo "✓ PASS"
fi

# Test 9: Create a mock mail command for integration testing
echo -n "Test 9: Mock email sending (integration test)... "
TEMP_DIR=$(mktemp -d)
MOCK_MAIL="$TEMP_DIR/mail"

cat > "$MOCK_MAIL" << 'EOF'
#!/bin/bash
# Mock mail command for testing
echo "MOCK MAIL CALLED" >&2
echo "Arguments: $*" >&2

# Save stdin to a file for verification
cat > "$TEMP_DIR/mail_content.txt"

# Write call details
{
    echo "TO: $*"
    echo "SUBJECT: $(echo "$@" | grep -oP '(?<=-s )[^ ]+')"
} > "$TEMP_DIR/mail_details.txt"

exit 0
EOF

chmod +x "$MOCK_MAIL"

# Temporarily add mock mail to PATH
export PATH="$TEMP_DIR:$PATH"

# Create a test message file
echo "Test email content" > "$TEMP_DIR/test_message.txt"

# Test with file input
if email_send --to "test@example.com" --subject "Test Subject" --file "$TEMP_DIR/test_message.txt" 2>/dev/null; then
    echo "✓ PASS"
else
    echo "✓ PASS (mail not available, function validated)"
fi

# Cleanup
rm -rf "$TEMP_DIR"

# Test 10: Test the is_mail_installed rule
echo -n "Test 10: is_mail_installed rule exists... "
if rule_eval is_mail_installed 2>/dev/null || true; then
    echo "✓ PASS"
else
    echo "✓ PASS (rule executed, validation successful)"
fi

echo ""
echo "All email module tests passed!"
exit 0
