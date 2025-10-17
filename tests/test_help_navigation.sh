#!/bin/bash
# Validate help navigation behaviour when forcing a pager

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BAR_CMD="$REPO_ROOT/bar"

first_line() {
    local line fd
    exec {fd}< <("$@")
    if IFS= read -r line <&$fd; then
        printf '%s\n' "$line"
        exec {fd}<&-
        return 0
    fi
    exec {fd}<&-
    return 1
}

first_non_empty_line() {
    local line fd
    exec {fd}< <("$@")
    while IFS= read -r line <&$fd; do
        [[ -z "$line" ]] && continue
        printf '%s\n' "$line"
        exec {fd}<&-
        return 0
    done
    exec {fd}<&-
    return 1
}

# 1. Indexed match should jump directly to ABOUT
if ! about_line="$(BAR_FORCE_PAGER=less first_line "$BAR_CMD" --bare help about)"; then
    echo "✗ help about command failed"
    exit 1
fi
if [[ "$about_line" =~ ^[[:space:]]*ABOUT[[:space:]]*$ ]]; then
    echo "✓ help about jumps to ABOUT"
else
    echo "✗ help about should start at ABOUT (got: $about_line)"
    exit 1
fi

# 2. Unknown query should fall back to full help without failing
if ! fallback_line="$(BAR_FORCE_PAGER=less first_non_empty_line "$BAR_CMD" --bare help __does_not_exist)"; then
    echo "✗ help fallback command failed"
    exit 1
fi
if [[ "$fallback_line" =~ ^[[:space:]]*bar[[:space:]]-- ]]; then
    echo "✓ help fallback prints full help when query is missing"
else
    echo "✗ help fallback should start with header (got: $fallback_line)"
    exit 1
fi

# 2b. Example documentation should not be treated as real symbol
if ! foo_line="$(BAR_FORCE_PAGER=less first_non_empty_line "$BAR_CMD" --bare help foo)"; then
    echo "✗ help foo command failed"
    exit 1
fi
if [[ "$foo_line" =~ foo ]]; then
    echo "✗ help foo should not jump to documentation example (got: $foo_line)"
    exit 1
else
    echo "✓ help foo does not treat documentation example as symbol"
fi

# 3. Partial function name should resolve to git_ls_files
if ! ls_line="$(BAR_FORCE_PAGER=less first_line "$BAR_CMD" --bare help ls_files)"; then
    echo "✗ help ls_files command failed"
    exit 1
fi
if [[ "$ls_line" =~ ls_files ]]; then
    echo "✓ help ls_files jumps to git_ls_files"
else
    echo "✗ help ls_files should show git_ls_files (got: $ls_line)"
    exit 1
fi

# 4. No query should still succeed under BAR_FORCE_PAGER when piped
if ! header_line="$(BAR_FORCE_PAGER=less first_non_empty_line "$BAR_CMD" --bare help)"; then
    echo "✗ help without query failed"
    exit 1
fi
if [[ "$header_line" =~ ^[[:space:]]*bar[[:space:]]-- ]]; then
    echo "✓ help without query works under BAR_FORCE_PAGER"
else
    echo "✗ help without query should start with header (got: $header_line)"
    exit 1
fi
