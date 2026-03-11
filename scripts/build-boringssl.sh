#!/bin/bash
# Build BoringSSL for ZyncBase
# This script builds BoringSSL as a static library

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BORINGSSL_DIR="$PROJECT_ROOT/vendor/boringssl"
BUILD_DIR="$BORINGSSL_DIR/build"

echo "Building BoringSSL..."

# Check if cmake is installed
if ! command -v cmake &> /dev/null; then
    echo "Error: cmake is not installed"
    echo "Please install cmake:"
    echo "  macOS: brew install cmake"
    echo "  Linux: sudo apt-get install cmake"
    exit 1
fi

# Check if go is installed (required by BoringSSL)
if ! command -v go &> /dev/null; then
    echo "Error: go is not installed (required by BoringSSL build)"
    echo "Please install go:"
    echo "  macOS: brew install go"
    echo "  Linux: sudo apt-get install golang"
    exit 1
fi

# Create build directory
mkdir -p "$BUILD_DIR"

# Configure and build only the libraries (not tests)
cd "$BUILD_DIR"
cmake -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release ..
cmake --build . --target crypto --parallel
cmake --build . --target ssl --parallel
cmake --build . --target decrepit --parallel

# Verify libraries were built
if [ ! -f "$BUILD_DIR/libssl.a" ]; then
    echo "Error: libssl.a was not built"
    exit 1
fi

if [ ! -f "$BUILD_DIR/libcrypto.a" ]; then
    echo "Error: libcrypto.a was not built"
    exit 1
fi

if [ ! -f "$BUILD_DIR/libdecrepit.a" ]; then
    echo "Error: libdecrepit.a was not built"
    exit 1
fi

echo "BoringSSL built successfully at $BUILD_DIR"
echo "Libraries:"
echo "  - $BUILD_DIR/libssl.a"
echo "  - $BUILD_DIR/libcrypto.a"
echo "  - $BUILD_DIR/libdecrepit.a"

