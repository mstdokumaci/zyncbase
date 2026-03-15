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

# 1. Apply patches
echo -e "\n${YELLOW}📦 Patching dependencies...${NC}"
./scripts/apply-patches.sh

# Determine macOS SDK path once
MACOS_SDK=""
if [[ "$OSTYPE" == "darwin"* ]]; then
    MACOS_SDK=$(xcrun --show-sdk-path 2>/dev/null || true)
    if [ -n "$MACOS_SDK" ]; then
        echo -e "${GREEN}✓ Found macOS SDK at: $MACOS_SDK${NC}"
    else
        echo -e "${YELLOW}⚠️  macOS SDK not found via xcrun. Framework linking may fail.${NC}"
    fi
fi

# 2. Iterate through matrix
for ENTRY in "${TARGETS[@]}"; do
    IFS="|" read -r TARGET NAME SUFFIX <<< "$ENTRY"
    
    echo -e "\n${BLUE}🏗️  Building for $NAME ($TARGET)...${NC}"
    
    # Define paths
    BORINGSSL_SRC="$PROJECT_ROOT/vendor/boringssl"
    BORINGSSL_BUILD="$BORINGSSL_SRC/build-$TARGET"
    ARTIFACT_DIR="$PROJECT_ROOT/releases/$SUFFIX"
    
    mkdir -p "$BORINGSSL_BUILD"
    mkdir -p "$ARTIFACT_DIR"
    
    # 2.a Build BoringSSL for target
    if [ ! -f "$BORINGSSL_BUILD/libssl.a" ]; then
        echo -e "   ${YELLOW}Compiling BoringSSL for $TARGET...${NC}"
        "$SCRIPT_DIR/build-boringssl.sh" "$TARGET" "$SUFFIX" "$BORINGSSL_BUILD" "$MACOS_SDK"
    else
        echo -e "   ${GREEN}✓ BoringSSL already built for $TARGET${NC}"
    fi
    
    # 2.b Build ZyncBase for target
    echo -e "   ${YELLOW}Compiling ZyncBase (ReleaseFast)...${NC}"
    
    # Point ZyncBase to our target-specific BoringSSL build
    export ZYNCBASE_BORINGSSL_PATH="$BORINGSSL_BUILD"
    
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
    
    # Pass SDK path to zig build if targeting macOS
    if [[ $TARGET == *"macos"* ]] && [[ -n "$MACOS_SDK" ]]; then
        ZIG_FLAGS+=("--sysroot" "$MACOS_SDK")
        ZIG_FLAGS+=("-Dsysroot=$MACOS_SDK")
        export SDKROOT="$MACOS_SDK"
    else
        unset SDKROOT
    fi
    
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
