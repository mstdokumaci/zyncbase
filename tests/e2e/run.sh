#!/bin/bash
set -e

# Configuration
PORT=3000
DATA_DIR="tests/e2e/data"
SERVER_BIN="./zig-out/bin/zyncbase"
SERVER_PID=""

echo "=== ZyncBase E2E Test Suite ==="

# Cleanup function for trap
cleanup() {
    echo "Cleaning up..."
    if [ -n "$SERVER_PID" ]; then
        kill $SERVER_PID 2>/dev/null || true
    fi
    rm -f test-artifacts/zyncbase-config.json test-artifacts/zyncbase-server-sync.log
}

# Set trap early to catch any exit
trap cleanup EXIT

wait_for_port() {
    local port=$1
    local retries=50
    local count=0
    # Try to connect to the port
    while ! nc -z 127.0.0.1 $port >/dev/null 2>&1; do
        sleep 0.1
        count=$((count + 1))
        if [ $count -ge $retries ]; then
            return 1
        fi
    done
    return 0
}

# Initial Cleanup
rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR"
rm -f test-artifacts/zyncbase-config.json test-artifacts/zyncbase-server-sync.log

# Build server
echo "Building ZyncBase server (ReleaseFast)..."
zig build -Doptimize=ReleaseFast

# 1. Bi-directional Sync Test
echo "--- Scenario 1: Bi-directional Sync ---"
# Create config for sync test
echo '{"server": {"port": '$PORT'}, "dataDir": "'$DATA_DIR'", "schema": "tests/e2e/schema-sync.json"}' > test-artifacts/zyncbase-config.json

$SERVER_BIN --config test-artifacts/zyncbase-config.json > test-artifacts/zyncbase-server-sync.log 2>&1 &
SERVER_PID=$!

echo "Waiting for server to start on port $PORT..."
wait_for_port $PORT || { echo "Server failed to start. Logs:"; cat test-artifacts/zyncbase-server-sync.log; exit 1; }

echo "Running sync test..."
bun tests/e2e/src/test-sync.ts || { echo "Sync test failed! Server log follows:"; cat test-artifacts/zyncbase-server-sync.log; exit 1; }

echo "Stopping server for persistence phase..."
kill $SERVER_PID
SERVER_PID=""
sleep 0.5

# 2. Persistence Test
echo "--- Scenario 2: Persistence ---"
# Create config for persistence test
echo '{"server": {"port": '$PORT'}, "dataDir": "'$DATA_DIR'", "schema": "tests/e2e/schema-persistence.json"}' > test-artifacts/zyncbase-config.json

# Set data
echo "Starting server to set data..."
$SERVER_BIN --config test-artifacts/zyncbase-config.json > /dev/null 2>&1 &
SERVER_PID=$!
wait_for_port $PORT

bun tests/e2e/src/test-persistence.ts set
kill $SERVER_PID
SERVER_PID=""
sleep 0.5

# Verify data after restart
echo "Restarting for verification..."
$SERVER_BIN --config test-artifacts/zyncbase-config.json > /dev/null 2>&1 &
SERVER_PID=$!
wait_for_port $PORT

bun tests/e2e/src/test-persistence.ts get
# Cleanup (kill and rm config) handled by trap EXIT

echo "=== All E2E Tests Passed! ==="
