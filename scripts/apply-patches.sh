#!/bin/bash
# Apply patches to Bun's uWebSockets to remove dependencies we don't need

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PATCHES_DIR="$PROJECT_ROOT/patches"
BUN_DIR="$PROJECT_ROOT/vendor/bun"

echo "Applying patches to Bun's uWebSockets..."

# Check if patches are already applied
cd "$BUN_DIR"
if git diff --quiet packages/bun-uws/src/PerMessageDeflate.h packages/bun-uws/src/WebSocketProtocol.h; then
    echo "Applying patches..."
    
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
    
    echo "Patches applied successfully"
else
    echo "Patches already applied or files modified"
fi
