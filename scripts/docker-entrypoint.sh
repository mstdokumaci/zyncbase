#!/usr/bin/env bash
set -euo pipefail

if [[ " $* " == *"sanitize=thread"* ]]; then
    bash /app/scripts/tsan-prep.sh
fi
exec zig "$@"