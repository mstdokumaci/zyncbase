#!/bin/bash
set -e

# Ensure we're in the project root
cd "$(dirname "$0")/.."

# Build Docker image if not present
if [[ "$(docker images -q zyncbase-repro 2> /dev/null)" == "" ]]; then
    echo "📦 Building Docker image..."
    docker build -t zyncbase-repro .
fi

PLATFORMS=("x86_64-linux" "aarch64-linux")
OPTIMIZE="ReleaseSafe"

echo "🏗️ Starting structured build for platforms: ${PLATFORMS[*]}"

for TARGET in "${PLATFORMS[@]}"; do
    echo "----------------------------------------------------------------"
    echo "👉 Building for $TARGET..."
    
    # Use Docker for Linux builds
    if [[ $TARGET == *"-linux" ]]; then
        docker run --rm -v "$(pwd):/app" zyncbase-repro build \
            -Dtarget="$TARGET" \
            -Doptimize="$OPTIMIZE" \
            --summary all
    else
        # Local build for macOS
        zig build -Dtarget="$TARGET" -Doptimize="$OPTIMIZE" --summary all
    fi
done

echo "✅ Build complete! Binaries are in zig-out/bin/"
