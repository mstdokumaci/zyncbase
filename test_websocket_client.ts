#!/usr/bin/env bun

/**
 * WebSocket client test for ZyncBase server integration
 * Run with: bunx test_websocket_client.ts
 */

const TEST_PORT = 9001;
const TEST_HOST = "127.0.0.1";
const TEST_URL = `ws://${TEST_HOST}:${TEST_PORT}`;

console.log("\n=== WebSocket Client Integration Test ===\n");

let testsPassed = 0;
let testsFailed = 0;

function pass(message: string) {
  console.log(`✓ ${message}`);
  testsPassed++;
}

function fail(message: string) {
  console.error(`✗ ${message}`);
  testsFailed++;
}

async function runTests() {
  try {
    // Test 1: Connect to WebSocket server
    console.log("Test 1: Connecting to WebSocket server...");
    const ws = new WebSocket(TEST_URL);

    // Wait for connection to open
    await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => {
        reject(new Error("Connection timeout after 5 seconds"));
      }, 5000);

      ws.onopen = () => {
        clearTimeout(timeout);
        pass("Connected to WebSocket server");
        resolve();
      };

      ws.onerror = (error) => {
        clearTimeout(timeout);
        reject(error);
      };
    });

    // Test 2: Send text message
    console.log("\nTest 2: Sending text message...");
    ws.send("Hello from Bun client!");
    pass("Text message sent");

    // Test 3: Send binary message
    console.log("\nTest 3: Sending binary message...");
    const binaryData = new Uint8Array([0x48, 0x65, 0x6c, 0x6c, 0x6f]); // "Hello"
    ws.send(binaryData);
    pass("Binary message sent");

    // Test 4: Receive messages (if server echoes)
    console.log("\nTest 4: Waiting for server responses...");
    await new Promise<void>((resolve) => {
      let messageCount = 0;
      const timeout = setTimeout(() => {
        if (messageCount === 0) {
          console.log("  (No messages received - server may not echo)");
        }
        resolve();
      }, 2000);

      ws.onmessage = (event) => {
        messageCount++;
        pass(`Received message: ${event.data}`);
        if (messageCount >= 2) {
          clearTimeout(timeout);
          resolve();
        }
      };
    });

    // Test 5: Close connection gracefully
    console.log("\nTest 5: Closing connection...");
    ws.close(1000, "Test complete");

    await new Promise<void>((resolve) => {
      ws.onclose = (event) => {
        pass(`Connection closed: code=${event.code}, reason="${event.reason}"`);
        resolve();
      };
    });

    // Summary
    console.log("\n=== Test Summary ===\n");
    console.log(`Tests passed: ${testsPassed}`);
    console.log(`Tests failed: ${testsFailed}`);

    if (testsFailed === 0) {
      console.log("\n✓ All integration tests passed!\n");
      process.exit(0);
    } else {
      console.log("\n✗ Some tests failed\n");
      process.exit(1);
    }
  } catch (error) {
    fail(`Test failed with error: ${error}`);
    console.log("\n=== Test Summary ===\n");
    console.log(`Tests passed: ${testsPassed}`);
    console.log(`Tests failed: ${testsFailed + 1}`);
    console.log("\n✗ Integration test failed\n");
    process.exit(1);
  }
}

// Run tests
runTests();
