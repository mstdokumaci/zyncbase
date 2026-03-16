#!/bin/bash
set -e

# Ensure we're in the project root
cd "$(dirname "$0")/.."

echo "🚀 Building Linux test environment..."
docker build -t zyncbase-repro .

echo "🧪 Running tests in Linux container..."
docker run --rm --memory 8g --entrypoint /bin/bash -v "$(pwd):/app" zyncbase-repro -c "
  zig build test --cache-dir /tmp/zig-cache -Dcpu=x86_64_v2 --summary all \"\$@\"
" -- "$@"
