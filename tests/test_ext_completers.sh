#!/bin/bash
# Test external completers and literal punctuation handling

# shellcheck disable=SC1091
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

source "$REPO_ROOT/contrib/bar_complete"

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
echo "Test 4: Testing literal punctuation extraction"

# Test _bar_extract_literal_punct function
echo "  Testing _bar_extract_literal_punct with '+toolchain'..."
result=$(_bar_extract_literal_punct "+toolchain")
result_array=()
while IFS= read -r line; do
    result_array+=("$line")
done <<< "$result"

if [[ "${result_array[0]}" == "toolchain" && "${result_array[1]}" == "+" && "${result_array[2]}" == "" ]]; then
    echo "✓ PASS: '+toolchain' → proto='toolchain', prefix='+', suffix=''"
else
    echo "✗ FAIL: Expected proto='toolchain', prefix='+', suffix=''"
    echo "  Got: proto='${result_array[0]}', prefix='${result_array[1]}', suffix='${result_array[2]}'"
fi

echo "  Testing _bar_extract_literal_punct with 'rule:'..."
result=$(_bar_extract_literal_punct "rule:")
result_array=()
while IFS= read -r line; do
    result_array+=("$line")
done <<< "$result"

if [[ "${result_array[0]}" == "rule" && "${result_array[1]}" == "" && "${result_array[2]}" == ":" ]]; then
    echo "✓ PASS: 'rule:' → proto='rule', prefix='', suffix=':'"
else
    echo "✗ FAIL: Expected proto='rule', prefix='', suffix=':'"
    echo "  Got: proto='${result_array[0]}', prefix='${result_array[1]}', suffix='${result_array[2]}'"
fi

echo "  Testing _bar_extract_literal_punct with '--flag'..."
result=$(_bar_extract_literal_punct "--flag")
result_array=()
while IFS= read -r line; do
    result_array+=("$line")
done <<< "$result"

if [[ "${result_array[0]}" == "--flag" && "${result_array[1]}" == "" && "${result_array[2]}" == "" ]]; then
    echo "✓ PASS: '--flag' → proto='--flag' (-- not stripped)"
else
    echo "✗ FAIL: Expected proto='--flag' with no literals"
    echo "  Got: proto='${result_array[0]}', prefix='${result_array[1]}', suffix='${result_array[2]}'"
fi

echo "  Testing _bar_extract_literal_punct with 'name..'..."
result=$(_bar_extract_literal_punct "name..")
result_array=()
while IFS= read -r line; do
    result_array+=("$line")
done <<< "$result"

if [[ "${result_array[0]}" == "name.." && "${result_array[1]}" == "" && "${result_array[2]}" == "" ]]; then
    echo "✓ PASS: 'name..' → proto='name..' (.. not stripped)"
else
    echo "✗ FAIL: Expected proto='name..' with no literals"
    echo "  Got: proto='${result_array[0]}', prefix='${result_array[1]}', suffix='${result_array[2]}'"
fi

echo ""
echo "External completer tests complete"
