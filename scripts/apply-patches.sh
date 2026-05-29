#!/bin/bash
# Apply patches to vendored dependencies

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PATCHES_DIR="$PROJECT_ROOT/patches"

echo "No patches required — uWebSockets modifications are permanently baked into vendor/uwebsockets/"
echo "See specs/implementation/patches.md for details."

exit 0
