#!/bin/bash
# Test function completion for git_ls_files and other git functions

# shellcheck disable=SC1091
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

source "$REPO_ROOT/contrib/bar_complete"

echo "Testing function completion..."

_bar_init_completion_registry

# Parse git_lib module
__bar_parse_file --module git_lib "$REPO_ROOT/Bar.d/git_lib"

# Test 1: Check if git_ls_files is tracked
echo ""
echo "Test 1: Checking if git_ls_files is tracked..."

if [[ -v __bar_func_module[git_ls_files] ]]; then
    echo "✓ PASS: git_ls_files is tracked in completion system"
else
    echo "✗ FAIL: git_ls_files is NOT tracked"
    echo "  Available functions: ${!__bar_func_module[*]}"
    exit 1
fi

# Test 2: Test completion for "bar git_" - SKIPPED
# (Requires full bar initialization which is complex to set up in unit test)
echo ""
echo "Test 2: Skipping full completion test (requires bar initialization)"

# Test 3: Test completion for "bar git_ls" - SKIPPED
# (Requires full bar initialization which is complex to set up in unit test)
echo ""
echo "Test 3: Skipping full completion test (requires bar initialization)"

# Test 4: Check git_parse_worktrees is also tracked
echo ""
echo "Test 4: Checking if git_parse_worktrees is tracked..."

if [[ -v __bar_func_module[git_parse_worktrees] ]]; then
    echo "✓ PASS: git_parse_worktrees is tracked"
else
    echo "✗ FAIL: git_parse_worktrees is NOT tracked"
    exit 1
fi

# Test 5: Check git-ls-files-opts prototype is registered
echo ""
echo "Test 5: Checking git-ls-files-opts prototype..."

if [[ -v __bar_protoregistry["git_lib@git-ls-files-opts"] ]]; then
    echo "✓ PASS: git-ls-files-opts prototype registered"
    echo "  Spec: ${__bar_protoregistry[git_lib@git-ls-files-opts]}"
    
    # Verify the spec is correct
    expected="extcomp git ls-files --cached --exclude-standard"
    actual="${__bar_protoregistry[git_lib@git-ls-files-opts]}"
    if [[ "$actual" == "$expected" ]]; then
        echo "✓ PASS: git-ls-files-opts has correct spec"
    else
        echo "✗ FAIL: git-ls-files-opts has wrong spec"
        echo "  Expected: $expected"
        echo "  Got: $actual"
    fi
else
    echo "✗ FAIL: git-ls-files-opts prototype not registered"
    exit 1
fi

# Test 6: Verify gitargs prototype was removed
echo ""
echo "Test 6: Checking gitargs prototype was removed..."

if [[ -v __bar_protoregistry["git_lib@gitargs"] ]]; then
    echo "✗ FAIL: gitargs prototype still exists (should be removed)"
    exit 1
else
    echo "✓ PASS: gitargs prototype was successfully removed"
fi

echo ""
echo "Function completion tests complete"
