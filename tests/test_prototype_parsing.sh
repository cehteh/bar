#!/bin/bash
# Test prototype definition parsing

# shellcheck disable=SC1091
# Source the completion script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

source "$REPO_ROOT/contrib/bar_complete"

# Initialize registry
__bar_init_completion_registry

echo "Testing prototype definition parsing..."

# Create a test module file
cat > /tmp/test_module_proto <<'EOF'
#!/bash
# Test module for prototype parsing

# prototype: "myfile" = "file existing"
# prototype: "mycommand" = "command"
# prototype: "custom" = "ext custom_complete"

function test_func ## <myfile> - test function
{
    echo "test"
}
EOF

# Parse the test file with module name
__bar_parse_file --module test_module /tmp/test_module_proto

# Check if prototypes were registered
if [[ -v __bar_protoregistry["test_module@myfile"] ]]; then
    echo "✓ myfile prototype registered with module"
    echo "  Value: ${__bar_protoregistry[test_module@myfile]}"
else
    echo "✗ myfile prototype not registered"
fi

if [[ -v __bar_protoregistry["test_module@mycommand"] ]]; then
    echo "✓ mycommand prototype registered with module"
    echo "  Value: ${__bar_protoregistry[test_module@mycommand]}"
else
    echo "✗ mycommand prototype not registered"
fi

if [[ -v __bar_protoregistry["test_module@custom"] ]]; then
    echo "✓ custom prototype registered with module"
    echo "  Value: ${__bar_protoregistry[test_module@custom]}"
else
    echo "✗ custom prototype not registered"
fi

# Test that the function was tracked with the module
if [[ -v __bar_func_module["test_func"] ]]; then
    echo "✓ test_func tracked to module: ${__bar_func_module[test_func]}"
else
    echo "✗ test_func module not tracked"
fi

# Test completer lookup with module context
completer=$(__bar_get_completer test_func myfile)
if [[ -n "$completer" ]]; then
    echo "✓ Completer lookup for test_func@myfile succeeded"
    echo "  Expanded completer: $completer"
else
    echo "✗ Completer lookup failed"
fi

# Cleanup
rm -f /tmp/test_module_proto

echo ""
echo "Prototype parsing tests complete"
