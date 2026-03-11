#!/bin/bash
set -e

# Ensure we're in the project root
cd "$(dirname "$0")/.."

echo "🚀 Building Linux test environment..."
docker build -t zyncbase-repro .

echo "🧪 Running tests in Linux container..."
docker run --rm -v "$(pwd):/app" zyncbase-repro build test "$@"
