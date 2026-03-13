#!/bin/bash
# Apply patches to vendored dependencies

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PATCHES_DIR="$PROJECT_ROOT/patches"
BUN_DIR="$PROJECT_ROOT/vendor/bun"
MSGPACK_DIR="$PROJECT_ROOT/vendor/zig_msgpack"

# 1. Apply patches to Bun's uWebSockets
echo "Applying patches to Bun's uWebSockets..."
cd "$BUN_DIR"
if git diff --quiet packages/bun-uws/src/PerMessageDeflate.h packages/bun-uws/src/WebSocketProtocol.h; then
    echo "Applying Bun patches..."
    
    # Apply libdeflate patch
    if [ -f "$PATCHES_DIR/bun-uws-disable-libdeflate.patch" ]; then
        git apply "$PATCHES_DIR/bun-uws-disable-libdeflate.patch"
        echo "  ✓ Applied libdeflate patch"
    fi
    
    # Apply SIMDUTF patch
    if [ -f "$PATCHES_DIR/bun-uws-disable-simdutf.patch" ]; then
        git apply "$PATCHES_DIR/bun-uws-disable-simdutf.patch"
        echo "  ✓ Applied SIMDUTF patch"
    fi
else
    echo "  - Bun patches already applied or files modified"
fi

# 2. Apply patches to zig-msgpack
echo "Applying patches to zig-msgpack..."
cd "$MSGPACK_DIR"
if git diff --quiet src/msgpack.zig; then
    if [ -f "$PATCHES_DIR/zig-msgpack-fix-leak.patch" ]; then
        git apply "$PATCHES_DIR/zig-msgpack-fix-leak.patch"
        echo "  ✓ Applied zig-msgpack-fix-leak patch"
    else
        echo "  ! zig-msgpack-fix-leak.patch not found"
    fi
else
    echo "  - zig-msgpack patches already applied or files modified"
fi

echo "All patches applied successfully"
