#!/bin/bash
# Test that help_indexer does not treat lines containing ' - ' as topics

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BAR_CMD="$REPO_ROOT/bar"

# Get all topics from help_indexer
topics_with_dash=$("$BAR_CMD" --bare help_indexer 2>/dev/null | grep '^[0-9]*-[0-9]*:topic:' | grep ' - ' || true)

if [[ -n "$topics_with_dash" ]]; then
    echo "✗ FAIL: Found topics containing ' - ' (these should be excluded):"
    echo "$topics_with_dash" | head -5
    exit 1
else
    echo "✓ PASS: No topics containing ' - ' found"
fi

# Verify that topics without ' - ' are still found
topics_count=$("$BAR_CMD" --bare help_indexer 2>/dev/null | grep -c '^[0-9]*-[0-9]*:topic:' || true)

if [[ "$topics_count" -eq 0 ]]; then
    echo "✗ FAIL: No topics found at all"
    exit 1
fi

echo "✓ PASS: Found $topics_count valid topics"

# Verify specific valid topics are still indexed (without ' - ')
valid_topics=$("$BAR_CMD" --bare help_indexer 2>/dev/null | grep '^[0-9]*-[0-9]*:topic:')

if echo "$valid_topics" | grep -q ':topic:ABOUT$'; then
    echo "✓ PASS: ABOUT topic is indexed"
else
    echo "✗ FAIL: ABOUT topic not found"
    exit 1
fi

if echo "$valid_topics" | grep -q ':topic:QUICKSTART$'; then
    echo "✓ PASS: QUICKSTART topic is indexed"
else
    echo "✗ FAIL: QUICKSTART topic not found"
    exit 1
fi

echo "✓ All tests passed"
