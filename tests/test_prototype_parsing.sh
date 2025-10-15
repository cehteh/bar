#!/bin/bash
# Test prototype definition parsing

# shellcheck disable=SC1091
# Source the completion script
source ../contrib/bar_complete

# Initialize registry
_bar_init_completion_registry

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
_bar_complete_parse_file --module test_module /tmp/test_module_proto

# Check if prototypes were registered
if [[ -v _bar_complete_protoregistry["test_module@myfile"] ]]; then
    echo "✓ myfile prototype registered with module"
    echo "  Value: ${_bar_complete_protoregistry[test_module@myfile]}"
else
    echo "✗ myfile prototype not registered"
fi

if [[ -v _bar_complete_protoregistry["test_module@mycommand"] ]]; then
    echo "✓ mycommand prototype registered with module"
    echo "  Value: ${_bar_complete_protoregistry[test_module@mycommand]}"
else
    echo "✗ mycommand prototype not registered"
fi

if [[ -v _bar_complete_protoregistry["test_module@custom"] ]]; then
    echo "✓ custom prototype registered with module"
    echo "  Value: ${_bar_complete_protoregistry[test_module@custom]}"
else
    echo "✗ custom prototype not registered"
fi

# Test that the function was tracked with the module
if [[ -v _bar_completion_func_module["test_func"] ]]; then
    echo "✓ test_func tracked to module: ${_bar_completion_func_module[test_func]}"
else
    echo "✗ test_func module not tracked"
fi

# Test completer lookup with module context
completer=$(_bar_get_completer test_func myfile)
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
