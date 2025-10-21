#!/bin/bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
# shellcheck shell=bash

# Test basic podman module functionality

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source bar for testing
cd "$REPO_ROOT" || exit 1
# shellcheck disable=SC1091
source ./bar

# Load podman module
require podman

echo "Testing podman module basic functionality..."

# Test 1: Check if is_podman_installed function exists
if ! declare -F is_podman_installed >/dev/null; then
    echo "FAIL: is_podman_installed function not found"
    exit 1
fi
echo "✓ PASS: is_podman_installed function exists"

# Test 2: Check if podman_run function exists
if ! declare -F podman_run >/dev/null; then
    echo "FAIL: podman_run function not found"
    exit 1
fi
echo "✓ PASS: podman_run function exists"

# Test 3: Check if is_podman_arch_available function exists
if ! declare -F is_podman_arch_available >/dev/null; then
    echo "FAIL: is_podman_arch_available function not found"
    exit 1
fi
echo "✓ PASS: is_podman_arch_available function exists"

# Test 4: Check if podman_image_build function exists
if ! declare -F podman_image_build >/dev/null; then
    echo "FAIL: podman_image_build function not found"
    exit 1
fi
echo "✓ PASS: podman_image_build function exists"

# Test 5: Check if podman_platform_complete function exists
if ! declare -F podman_platform_complete >/dev/null; then
    echo "FAIL: podman_platform_complete function not found"
    exit 1
fi
echo "✓ PASS: podman_platform_complete function exists"

# Test 6: Test podman_platform_complete returns platforms
platforms=$(podman_platform_complete)
if [[ -z "$platforms" ]]; then
    echo "FAIL: podman_platform_complete returned no platforms"
    exit 1
fi
if ! echo "$platforms" | grep -q "linux/amd64"; then
    echo "FAIL: podman_platform_complete missing linux/amd64"
    exit 1
fi
echo "✓ PASS: podman_platform_complete returns platforms"

# Test 7: Test is_podman_installed (may pass or fail depending on system)
if command -v podman >/dev/null 2>&1; then
    if is_podman_installed; then
        echo "✓ PASS: is_podman_installed correctly detects podman"
    else
        echo "FAIL: is_podman_installed failed but podman is available"
        exit 1
    fi
else
    if ! is_podman_installed; then
        echo "✓ PASS: is_podman_installed correctly reports podman not installed"
    else
        echo "FAIL: is_podman_installed succeeded but podman is not available"
        exit 1
    fi
fi

# Test 8: Test podman_version (only if podman is installed)
if command -v podman >/dev/null 2>&1; then
    version=$(podman_version)
    if [[ -n "$version" ]]; then
        echo "✓ PASS: podman_version returns: $version"
    else
        echo "FAIL: podman_version returned empty"
        exit 1
    fi
fi

# Test 9: Test is_podman_arch_available with native architecture
native_arch=$(uname -m)
if command -v podman >/dev/null 2>&1; then
    if is_podman_arch_available "$native_arch"; then
        echo "✓ PASS: is_podman_arch_available detects native arch: $native_arch"
    else
        echo "FAIL: is_podman_arch_available failed for native arch: $native_arch"
        exit 1
    fi
fi

# Test 10: Test Phase 2 functions exist
echo ""
echo "Testing Phase 2 functions..."

if ! declare -F podman_arch_setup >/dev/null; then
    echo "FAIL: podman_arch_setup function not found"
    exit 1
fi
echo "✓ PASS: podman_arch_setup function exists"

if ! declare -F is_qemu_available >/dev/null; then
    echo "FAIL: is_qemu_available function not found"
    exit 1
fi
echo "✓ PASS: is_qemu_available function exists"

if ! declare -F podman_image_build_multiarch >/dev/null; then
    echo "FAIL: podman_image_build_multiarch function not found"
    exit 1
fi
echo "✓ PASS: podman_image_build_multiarch function exists"

if ! declare -F podman_image_build_matrix >/dev/null; then
    echo "FAIL: podman_image_build_matrix function not found"
    exit 1
fi
echo "✓ PASS: podman_image_build_matrix function exists"

if ! declare -F podman_run_arch >/dev/null; then
    echo "FAIL: podman_run_arch function not found"
    exit 1
fi
echo "✓ PASS: podman_run_arch function exists"

if ! declare -F podman_get_native_arch >/dev/null; then
    echo "FAIL: podman_get_native_arch function not found"
    exit 1
fi
echo "✓ PASS: podman_get_native_arch function exists"

if ! declare -F podman_list_available_archs >/dev/null; then
    echo "FAIL: podman_list_available_archs function not found"
    exit 1
fi
echo "✓ PASS: podman_list_available_archs function exists"

# Test 11: Test podman_get_native_arch returns something
native=$(podman_get_native_arch)
if [[ -z "$native" ]]; then
    echo "FAIL: podman_get_native_arch returned empty"
    exit 1
fi
echo "✓ PASS: podman_get_native_arch returns: $native"

# Test 12: Test Phase 3 functions exist
echo ""
echo "Testing Phase 3 functions..."

if ! declare -F podman_image_snapshot >/dev/null; then
    echo "FAIL: podman_image_snapshot function not found"
    exit 1
fi
echo "✓ PASS: podman_image_snapshot function exists"

if ! declare -F podman_layer_bar >/dev/null; then
    echo "FAIL: podman_layer_bar function not found"
    exit 1
fi
echo "✓ PASS: podman_layer_bar function exists"

if ! declare -F podman_layer_toolchain >/dev/null; then
    echo "FAIL: podman_layer_toolchain function not found"
    exit 1
fi
echo "✓ PASS: podman_layer_toolchain function exists"

if ! declare -F podman_layer_dev >/dev/null; then
    echo "FAIL: podman_layer_dev function not found"
    exit 1
fi
echo "✓ PASS: podman_layer_dev function exists"

if ! declare -F podman_containerfile_from >/dev/null; then
    echo "FAIL: podman_containerfile_from function not found"
    exit 1
fi
echo "✓ PASS: podman_containerfile_from function exists"

if ! declare -F podman_containerfile_run >/dev/null; then
    echo "FAIL: podman_containerfile_run function not found"
    exit 1
fi
echo "✓ PASS: podman_containerfile_run function exists"

if ! declare -F podman_containerfile_copy >/dev/null; then
    echo "FAIL: podman_containerfile_copy function not found"
    exit 1
fi
echo "✓ PASS: podman_containerfile_copy function exists"

if ! declare -F podman_containerfile_env >/dev/null; then
    echo "FAIL: podman_containerfile_env function not found"
    exit 1
fi
echo "✓ PASS: podman_containerfile_env function exists"

if ! declare -F podman_containerfile_workdir >/dev/null; then
    echo "FAIL: podman_containerfile_workdir function not found"
    exit 1
fi
echo "✓ PASS: podman_containerfile_workdir function exists"

if ! declare -F podman_containerfile_build >/dev/null; then
    echo "FAIL: podman_containerfile_build function not found"
    exit 1
fi
echo "✓ PASS: podman_containerfile_build function exists"

echo ""
echo "All basic podman module tests passed (Phase 1 + Phase 2 + Phase 3)!"
