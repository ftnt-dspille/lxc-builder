#!/bin/bash

# Comprehensive test suite for LXC Image Builder
# This script tests different distributions, error conditions, and code paths

set -euo pipefail

echo "🧪 LXC Image Builder Test Suite"
echo "==============================="

# Function to run test and capture result
run_test() {
    local test_name="$1"
    local command="$2"
    local should_fail="${3:-false}"

    echo ""
    echo "🔍 Testing: $test_name"
    echo "Command: $command"
    echo "Expected: $([ "$should_fail" = "true" ] && echo "FAIL" || echo "SUCCESS")"
    echo "----------------------------------------"

    if [ "$should_fail" = "true" ]; then
        if ! eval "$command"; then
            echo "✅ Test PASSED (expected failure)"
        else
            echo "❌ Test FAILED (should have failed)"
        fi
    else
        if eval "$command"; then
            echo "✅ Test PASSED"
        else
            echo "❌ Test FAILED"
        fi
    fi
}

# Test 1: Help messages (should work without Docker)
echo "=== HELP SYSTEM TESTS ==="
run_test "Wrapper help message" "./build-lxc-wrapper.sh --help"
run_test "Build script help message" "./build-lxc.sh --help"

# Test 2: Error conditions (should fail gracefully)
echo "=== ERROR HANDLING TESTS ==="
run_test "Invalid distribution" "./build-lxc-wrapper.sh invalid-distro" true
run_test "Invalid wrapper option" "./build-lxc-wrapper.sh --invalid-option" true
run_test "Invalid build script option" "./build-lxc.sh --invalid-option" true

# Test 3: Quick builds (different package managers and systems)
echo "=== QUICK BUILD TESTS ==="
echo "⚠️  These require Docker and will download base images"
read -p "Continue with Docker tests? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then

    # Test different distribution families
    run_test "Debian family (apt)" "./build-lxc-wrapper.sh debian trixie"
    run_test "Ubuntu family (apt)" "./build-lxc-wrapper.sh ubuntu jammy"
    run_test "RedHat family (dnf)" "./build-lxc-wrapper.sh fedora 39"
    run_test "Alpine family (apk)" "./build-lxc-wrapper.sh alpine 3.19"

    # Test variant fallback mechanism
    run_test "Variant fallback test" "./build-lxc-wrapper.sh alpine 3.19 amd64 nonexistent-variant"

    # Test custom options
    run_test "Custom zip name" "./build-lxc-wrapper.sh --zip-name 'test-custom' debian trixie"
    run_test "Custom output directory" "./build-lxc-wrapper.sh -o /tmp/lxc-test ubuntu jammy"

    # Test no-build option (should fail first time)
    run_test "No-build without image" "./build-lxc-wrapper.sh --no-build debian trixie" true

    # Build image first, then test no-build
    echo "Building Docker image for no-build test..."
    docker build -t lxc-builder . -q
    run_test "No-build with existing image" "./build-lxc-wrapper.sh --no-build debian trixie"

    # Test cache hit (second run should be faster)
    run_test "Cache hit test (second build)" "./build-lxc-wrapper.sh debian trixie"

else
    echo "⏭️  Skipping Docker-dependent tests"
fi

# Test 4: Direct script usage (if on Linux with LXC)
if command -v lxc-create &> /dev/null; then
    echo "=== DIRECT SCRIPT TESTS (LXC Available) ==="
    run_test "Direct script with options" "sudo ./build-lxc.sh -d debian -r trixie -o /tmp/direct-test"
    run_test "Direct script help" "./build-lxc.sh --help"
else
    echo "⏭️  Skipping direct LXC tests (lxc-create not available)"
fi

# Test 5: Docker validation
echo "=== DOCKER VALIDATION TESTS ==="
if command -v docker &> /dev/null; then
    if docker info &> /dev/null; then
        echo "✅ Docker is available and running"
    else
        echo "⚠️  Docker is installed but not running"
        run_test "Docker not running error" "./build-lxc-wrapper.sh debian" true
    fi
else
    echo "⚠️  Docker not installed - testing error handling"
    # Temporarily rename docker command to test error handling
    if [ -f /usr/bin/docker ]; then
        sudo mv /usr/bin/docker /usr/bin/docker.bak
        run_test "Docker not installed error" "./build-lxc-wrapper.sh debian" true
        sudo mv /usr/bin/docker.bak /usr/bin/docker
    fi
fi

echo ""
echo "🏁 Test Suite Complete!"
echo "======================="
echo ""
echo "📁 Check output directories:"
echo "   - ./out/ (default output)"
echo "   - /tmp/lxc-test/ (custom output test)"
echo "   - /tmp/direct-test/ (direct script test)"
echo ""
echo "🧹 Cleanup commands:"
echo "   rm -rf ./out/* ./lxc-cache/* /tmp/lxc-test /tmp/direct-test"
echo "   docker system prune -f"