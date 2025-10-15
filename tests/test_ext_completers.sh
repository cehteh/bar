#!/bin/bash
# Test external completers and literal punctuation handling

# shellcheck disable=SC1091
source ../contrib/bar_complete

echo "Testing external completers and literal punctuation..."
echo ""

# Test 1: External completer function
echo "Test 1: Testing external completer setup"

# Create a mock external completer function
function test_ext_complete()
{
    echo "option1"
    echo "option2"
    echo "option3"
}

# Initialize registry and add the external completer
_bar_init_completion_registry
_bar_complete_protoregistry["testproto"]="ext test_ext_complete"

# Get the expanded completer
completer=$(_bar_get_completer "" "testproto")
echo "  Expanded completer: $completer"

if [[ "$completer" == "_bar_complete_comp_ext test_ext_complete" ]]; then
    echo "✓ PASS: External completer expanded correctly"
else
    echo "✗ FAIL: Expected '_bar_complete_comp_ext test_ext_complete', got '$completer'"
fi

# Test 2: Call the external completer
echo ""
echo "Test 2: Calling external completer"

# Mock bar --bare to return some results
function bar()
{
    if [[ "$1" == "--bare" && "$2" == "test_ext_complete" ]]; then
        echo "result1"
        echo "result2"
        return 0
    fi
    return 1
}

results=$(_bar_complete_comp_ext "test_ext_complete" "res")
result_count=$(echo "$results" | wc -l)

if [[ $result_count -ge 2 ]]; then
    echo "✓ PASS: External completer returned results"
else
    echo "✗ FAIL: External completer did not return expected results"
fi

echo ""
echo "Test 3: Testing literal punctuation in prototypes"

# Test parsing of <+toolchain>
echo "  Testing <+toolchain> parsing..."
protos=$(_bar_parse_protos "<+toolchain>")
proto_array=()
while IFS= read -r line; do
    [[ -n "$line" ]] && proto_array+=("$line")
done <<< "$protos"

echo "  Parsed prototypes: ${proto_array[*]}"
if [[ "${proto_array[0]}" == "+toolchain" ]]; then
    echo "✓ PASS: <+toolchain> parsed as '+toolchain'"
else
    echo "✗ FAIL: Expected '+toolchain', got '${proto_array[0]}'"
fi

# Test parsing of <rule:>
echo ""
echo "  Testing <rule:> parsing..."
protos=$(_bar_parse_protos "<rule:>")
proto_array=()
while IFS= read -r line; do
    [[ -n "$line" ]] && proto_array+=("$line")
done <<< "$protos"

echo "  Parsed prototypes: ${proto_array[*]}"
if [[ "${proto_array[0]}" == "rule:" ]]; then
    echo "✓ PASS: <rule:> parsed as 'rule:'"
else
    echo "✗ FAIL: Expected 'rule:', got '${proto_array[0]}'"
fi

# Test parsing of [+toolchain]
echo ""
echo "  Testing [+toolchain] parsing..."
protos=$(_bar_parse_protos "[+toolchain]")
proto_array=()
while IFS= read -r line; do
    [[ -n "$line" ]] && proto_array+=("$line")
done <<< "$protos"

echo "  Parsed prototypes: ${proto_array[*]}"
if [[ "${proto_array[0]}" == "[+toolchain]" ]]; then
    echo "✓ PASS: [+toolchain] parsed as '[+toolchain]' (optional)"
else
    echo "✗ FAIL: Expected '[+toolchain]', got '${proto_array[0]}'"
fi

echo ""
echo "Test 4: Testing literal punctuation with actual prototypes"

# The literal + should be handled separately from the prototype
# When we have <+toolchain>, it should be split into literal "+" and prototype "toolchain"
# This needs to be implemented in the parser

echo "  Current implementation extracts full content including punctuation"
echo "  TODO: Implement splitting of literal punctuation from prototypes"

echo ""
echo "External completer tests complete"
