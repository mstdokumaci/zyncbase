#!/usr/bin/env bun

/**
 * Comprehensive WebSocket test for ZyncBase server
 * Tests all callback events: open, message, close
 */

const TEST_PORT = 9001;
const TEST_HOST = "127.0.0.1";
const TEST_URL = `ws://${TEST_HOST}:${TEST_PORT}`;

console.log("\n=== Comprehensive WebSocket Test ===\n");

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

async function testWebSocketCallbacks() {
  console.log("Test: Verifying all WebSocket callbacks are invoked\n");

  const ws = new WebSocket(TEST_URL);
  let openCalled = false;
  let messageCalled = false;
  let closeCalled = false;

  // Test open callback
  await new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error("Connection timeout"));
    }, 5000);

    ws.onopen = () => {
      clearTimeout(timeout);
      openCalled = true;
      pass("Open callback invoked");
      resolve();
    };

    ws.onerror = (error) => {
      clearTimeout(timeout);
      reject(error);
    };
  });

  // Test message callback (text)
  await new Promise<void>((resolve) => {
    ws.onmessage = (event) => {
      messageCalled = true;
      pass(`Message callback invoked (text): ${event.data}`);
      resolve();
    };

    ws.send("Test text message");
  });

  // Test message callback (binary)
  await new Promise<void>((resolve) => {
    ws.onmessage = (event) => {
      pass(`Message callback invoked (binary): ${event.data}`);
      resolve();
    };

    const binaryData = new Uint8Array([0x01, 0x02, 0x03, 0x04]);
    ws.send(binaryData);
  });

  // Test close callback
  await new Promise<void>((resolve) => {
    ws.onclose = (event) => {
      closeCalled = true;
      pass(`Close callback invoked: code=${event.code}`);
      resolve();
    };

    ws.close(1000, "Test complete");
  });

  // Verify all callbacks were invoked
  if (openCalled && messageCalled && closeCalled) {
    pass("All callbacks verified");
  } else {
    fail("Not all callbacks were invoked");
  }
}

async function testMultipleConnections() {
  console.log("\nTest: Multiple concurrent connections\n");

  const connections = [];
  const numConnections = 5;

  for (let i = 0; i < numConnections; i++) {
    const ws = new WebSocket(TEST_URL);
    connections.push(
      new Promise<void>((resolve) => {
        ws.onopen = () => {
          ws.send(`Connection ${i}`);
        };
        ws.onmessage = () => {
          ws.close();
        };
        ws.onclose = () => {
          resolve();
        };
      })
    );
  }

  await Promise.all(connections);
  pass(`${numConnections} concurrent connections handled successfully`);
}

async function runAllTests() {
  try {
    await testWebSocketCallbacks();
    await testMultipleConnections();

    console.log("\n=== Test Summary ===\n");
    console.log(`Tests passed: ${testsPassed}`);
    console.log(`Tests failed: ${testsFailed}`);

    if (testsFailed === 0) {
      console.log("\n✓ All comprehensive tests passed!\n");
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
    console.log("\n✗ Comprehensive test failed\n");
    process.exit(1);
  }
}

runAllTests();
