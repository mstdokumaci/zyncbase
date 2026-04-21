#!/bin/bash
# Unified BoringSSL Builder for ZyncBase
# Handles both native and cross-compilation using Zig
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BORINGSSL_DIR="$PROJECT_ROOT/vendor/boringssl"

TARGET="${1:-native}"
SUFFIX="${2:-}" # Optional suffix for build directory naming
BUILD_DIR="${3:-$BORINGSSL_DIR/build}"
MACOS_SDK="$4"

if command -v ninja &> /dev/null; then
    GENERATOR="Ninja"
    BUILD_CMD="ninja"
else
    GENERATOR="Unix Makefiles"
    BUILD_CMD="make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
fi

if [[ "$TARGET" == "native" ]]; then
    echo "Building BoringSSL for native target..."
else
    echo "Building BoringSSL for target: $TARGET..."
fi

TARGET_STAMP="$BUILD_DIR/.zyncbase-target"
CACHE_FILE="$BUILD_DIR/CMakeCache.txt"
if [[ -f "$TARGET_STAMP" ]] && [[ "$(cat "$TARGET_STAMP")" != "$TARGET" ]]; then
    echo "Build directory target changed. Cleaning $BUILD_DIR..."
    rm -rf "$BUILD_DIR"
fi

if [[ -f "$CACHE_FILE" ]]; then
    CACHED_GENERATOR="$(sed -n 's/^CMAKE_GENERATOR:INTERNAL=//p' "$CACHE_FILE" | head -n 1)"
    CACHED_SOURCE_DIR="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$CACHE_FILE" | head -n 1)"

    if [[ -n "$CACHED_GENERATOR" ]] && [[ "$CACHED_GENERATOR" != "$GENERATOR" ]]; then
        echo "CMake generator changed from '$CACHED_GENERATOR' to '$GENERATOR'. Cleaning $BUILD_DIR..."
        rm -rf "$BUILD_DIR"
    elif [[ -n "$CACHED_SOURCE_DIR" ]] && [[ "$CACHED_SOURCE_DIR" != "$BORINGSSL_DIR" ]]; then
        echo "CMake source directory changed. Cleaning $BUILD_DIR..."
        rm -rf "$BUILD_DIR"
    fi
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Create the Zig wrapper script to handle assembler flag issues
ZIG_WRAPPER="$(pwd)/zig-wrapper.sh"
cat > "$ZIG_WRAPPER" <<EOF
#!/bin/bash
REAL_CMD=\$1
if [[ "\$REAL_CMD" == "cc" ]] || [[ "\$REAL_CMD" == "c++" ]]; then
    CMD="\$REAL_CMD"
    shift
elif [[ "\$REAL_CMD" == -* ]]; then
    CMD="cc"
else
    # Default to cc if we're not sure, but keep the arg if it's not a known zig command
    CMD="cc"
fi

ARGS=()
for arg in "\$@"; do
    if [[ "\$arg" != "-Wa,-g" ]]; then
        ARGS+=("\$arg")
    fi
done

EXTRA_FLAGS=()
if [[ "$TARGET" != "native" ]]; then
    EXTRA_FLAGS+=("-target" "$TARGET")
fi

if [[ -n "$MACOS_SDK" ]]; then
    EXTRA_FLAGS+=("-isysroot" "$MACOS_SDK")
fi

if [[ "$TARGET" == "x86_64"* ]]; then
    EXTRA_FLAGS+=("-march=x86_64_v2")
fi

exec zig "\$CMD" "\${EXTRA_FLAGS[@]}" "\${ARGS[@]}"
EOF
chmod +x "$ZIG_WRAPPER"

EXTRA_CMAKE_FLAGS=()
if [[ "$TARGET" == *"macos"* ]]; then
    # Extract architecture from target (e.g., x86_64 from x86_64-macos)
    ARCH=$(echo "$TARGET" | cut -d'-' -f1)
    if [[ "$ARCH" == "aarch64" ]]; then ARCH="arm64"; fi
    EXTRA_CMAKE_FLAGS+=("-DCMAKE_OSX_ARCHITECTURES=$ARCH")
fi

cmake -G "$GENERATOR" \
      "${EXTRA_CMAKE_FLAGS[@]}" \
      -DCMAKE_C_COMPILER="$ZIG_WRAPPER" \
      -DCMAKE_CXX_COMPILER="$ZIG_WRAPPER" \
      -DCMAKE_ASM_COMPILER="$ZIG_WRAPPER" \
      -DCMAKE_C_COMPILER_ARG1="cc" \
      -DCMAKE_CXX_COMPILER_ARG1="c++" \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF \
      -DBUILD_TESTING=OFF \
      ..

# Build
$BUILD_CMD crypto ssl decrepit

echo "$TARGET" > "$TARGET_STAMP"

echo "✓ BoringSSL built successfully at $BUILD_DIR"
