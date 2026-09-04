#!/bin/bash
# ZyncBase Release Matrix Build Script
# Targets: macOS (aarch64, x86_64), Linux (aarch64, x86_64)
# Optimization: ReleaseFast

set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Ensure we're in the project root
cd "$(dirname "$0")/.."
PROJECT_ROOT=$(pwd)

echo -e "${BLUE}🚀 Starting ZyncBase Release Matrix Build${NC}"
echo -e "${BLUE}========================================${NC}"

# Matrix definition
# format: "zig-target-name|friendly-name|binary-suffix"
TARGETS=(
    "aarch64-macos|macOS Silicon|macos-aarch64"
    "x86_64-macos|macOS Intel|macos-x86_64"
    "aarch64-linux-gnu|Linux ARM64|linux-aarch64"
    "x86_64-linux-gnu|Linux x86_64|linux-x86_64"
)

# Native builds — no sysroot needed (linkFramework finds SDK)

# 2. Iterate through matrix
for ENTRY in "${TARGETS[@]}"; do
    IFS="|" read -r TARGET NAME SUFFIX <<< "$ENTRY"
    
    echo -e "\n${BLUE}🏗️  Building for $NAME ($TARGET)...${NC}"
    
    # Define paths
    ARTIFACT_DIR="$PROJECT_ROOT/releases/$SUFFIX"
    
    mkdir -p "$ARTIFACT_DIR"
    
    # Build ZyncBase for target
    echo -e "   ${YELLOW}Compiling ZyncBase (ReleaseFast)...${NC}"
    
    ZIG_FLAGS=(
        "build"
        "-Dtarget=$TARGET"
        "-Doptimize=ReleaseFast"
        "--prefix" "$ARTIFACT_DIR"
        "--summary" "all"
    )
    if [[ $TARGET == "x86_64"* ]]; then
        ZIG_FLAGS+=("-Dcpu=x86_64_v2")
    fi
    
    # Native — no sysroot
    
    zig "${ZIG_FLAGS[@]}" > build_zig_error.log 2>&1 || {
        echo -e "${YELLOW}Build failed. Error log:${NC}"
        cat build_zig_error.log
        exit 1
    }
              
    echo -e "   ${GREEN}✓ Build complete: releases/$SUFFIX/bin/zyncbase${NC}"
done

echo -e "\n${BLUE}========================================${NC}"
echo -e "${GREEN}✅ All targets built successfully in releases/ folder!${NC}"
ls -lR releases/
