#! /bin/bash -e
# Copyright © 2026 Apple Inc. and the container project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# =============================================================================
# setup-test-env.sh — Test environment setup for container project
#
# This script prepares the test environment by:
#   1. Building the container CLI binary
#   2. Installing it to bin/container (required by CLITest)
#   3. Installing the recommended Linux kernel
#   4. Starting the container system service
#
# Usage:
#   ./scripts/setup-test-env.sh                    # Default setup
#   ./scripts/setup-test-env.sh --app-root /tmp/t   # Custom app root
#   ./scripts/setup-test-env.sh --skip-build         # Skip Swift build
#   ./scripts/setup-test-env.sh --skip-kernel        # Skip kernel install
#   ./scripts/setup-test-env.sh --help               # Show help
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-debug}"
SKIP_BUILD=false
SKIP_KERNEL=false
START_ARGS=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Prepare the test environment for the container project.

Options:
    -a, --app-root APP_ROOT    Use custom APP_ROOT for system data
    -l, --log-root LOG_ROOT    Use custom LOG_ROOT for system logs
    --skip-build               Skip Swift build step
    --skip-kernel              Skip kernel download and install
    -h, --help                 Show this help message

Environment variables:
    BUILD_CONFIGURATION        Build configuration (debug|release, default: debug)
    SWIFT                      Swift compiler path (default: /usr/bin/swift)

Examples:
    # Full setup with isolated test data directory:
    ./scripts/setup-test-env.sh --app-root /tmp/container-test

    # Quick setup (skip build if already built):
    ./scripts/setup-test-env.sh --skip-build

    # Setup without kernel (use existing kernel):
    ./scripts/setup-test-env.sh --skip-kernel
EOF
    exit 0
}

# Parse command line options
while [[ $# -gt 0 ]]; do
    case $1 in
        -a|--app-root)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: Option $1 requires an argument." >&2
                exit 1
            fi
            START_ARGS+=(--app-root "$2")
            shift 2
            ;;
        -l|--log-root)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: Option $1 requires an argument." >&2
                exit 1
            fi
            START_ARGS+=(--log-root "$2")
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-kernel)
            SKIP_KERNEL=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            usage
            ;;
    esac
done

echo "============================================"
echo "  Container Test Environment Setup"
echo "============================================"
echo "Project: $PROJECT_DIR"
echo "Config:  $BUILD_CONFIGURATION"
echo ""

# ---- Step 1: Build ----
if [[ "$SKIP_BUILD" == "false" ]]; then
    echo "--- Step 1/4: Building container CLI ---"
    SWIFT="${SWIFT:-/usr/bin/swift}"
    $SWIFT build -c "$BUILD_CONFIGURATION"

    BUILD_BIN_DIR=$($SWIFT build -c "$BUILD_CONFIGURATION" --show-bin-path)
    echo "Build output: $BUILD_BIN_DIR"

    echo "Installing CLI to bin/container..."
    mkdir -p "$PROJECT_DIR/bin"
    install "$BUILD_BIN_DIR/container" "$PROJECT_DIR/bin/container"
    echo "✅ CLI binary installed at bin/container"
else
    echo "--- Step 1/4: Build skipped (--skip-build) ---"
fi
echo ""

# ---- Step 2: Build background services ----
if [[ "$SKIP_BUILD" == "false" ]]; then
    echo "--- Step 2/4: Building background services ---"
    make container BUILD_CONFIGURATION="$BUILD_CONFIGURATION"
    echo "✅ Background services built"
else
    echo "--- Step 2/4: Services build skipped (--skip-build) ---"
fi
echo ""

# ---- Step 3: Stop any running system ----
echo "--- Step 3/4: Stopping any running container system ---"
if command -v container &>/dev/null || [[ -f "$PROJECT_DIR/bin/container" ]]; then
    CONTAINER_BIN="${PROJECT_DIR}/bin/container"
    $CONTAINER_BIN system stop 2>/dev/null || true
    echo "✅ System stopped"
else
    echo "⚠️  container binary not found, skipping stop"
fi
echo ""

# ---- Step 4: Start system and install kernel ----
echo "--- Step 4/4: Starting system and installing kernel ---"
CONTAINER_BIN="${PROJECT_DIR}/bin/container"

if [[ "$SKIP_KERNEL" == "false" ]]; then
    echo "Starting system with kernel auto-install (timeout: 120s)..."
    # --enable-kernel-install allows auto-install of the recommended kernel
    $CONTAINER_BIN --debug system start --timeout 120 --enable-kernel-install "${START_ARGS[@]}"
    echo "✅ System started with kernel installed"
else
    echo "Kernel install skipped (--skip-kernel). Starting system without kernel install..."
    $CONTAINER_BIN system start "${START_ARGS[@]}" 2>/dev/null || true
    echo "⚠️  System may not have a kernel — some tests will fail"
fi
echo ""

echo "============================================"
echo "  Environment ready!"
echo "  Binary:     $PROJECT_DIR/bin/container"
echo "  Config:     $BUILD_CONFIGURATION"
echo "  Kernel:     $([[ "$SKIP_KERNEL" == "false" ]] && echo 'Installed' || echo 'Skipped')"
echo ""
echo "  Run tests:  swift test"
echo "  Or:         make test"
echo "============================================"
