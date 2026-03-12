#!/usr/bin/env bun

/**
 * Comprehensive Integration Tests for ZyncBase Server
 * 
 * Tests Requirements 20.1-20.8:
 * - Server executable runs and listens on configured port
 * - WebSocket client can connect
 * - StoreSet message stores data and returns success
 * - StoreGet message retrieves data and returns value
 * - Data persists across server restarts
 * - SIGTERM triggers graceful shutdown within 5 seconds
 * 
 * Usage:
 *   1. Build server: zig build
 *   2. Run tests: bunx test_integration.ts
 */

import { spawn, type Subprocess } from "bun";
import { encode, decode } from "@msgpack/msgpack";

const TEST_PORT = 9001;
const TEST_HOST = "127.0.0.1";
const TEST_URL = `ws://${TEST_HOST}:${TEST_PORT}`;
const SERVER_BINARY = "./zig-out/bin/zyncbase";
const DATA_DIR = "./test-data";
const CONFIG_FILE = "./zyncbase-config.json";

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

// Helper to create test configuration
async function createTestConfig() {
  const config = {
    server: {
      port: TEST_PORT,
      host: TEST_HOST,
      maxConnections: 100,
    },
    dataDir: DATA_DIR,
    logging: {
      level: "info",
      format: "text",
    },
  };

  await Bun.write(CONFIG_FILE, JSON.stringify(config, null, 2));
}

// Helper to clean up test data
async function cleanupTestData() {
  try {
    await Bun.$`rm -rf ${DATA_DIR}`;
    await Bun.$`rm -f ${CONFIG_FILE}`;
  } catch (e) {
    // Ignore errors if files don't exist
  }
}

// Helper to start the server
async function startServer(): Promise<Subprocess> {
  console.log(`Starting ZyncBase server from ${SERVER_BINARY}...`);
  
  const proc = spawn([SERVER_BINARY], {
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env },
  });

  // Wait for server to be ready (check for startup message or port binding)
  await new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error("Server startup timeout after 5 seconds"));
    }, 5000);

    // Try to connect to verify server is ready
    const checkReady = setInterval(async () => {
      try {
        const ws = new WebSocket(TEST_URL);
        ws.onopen = () => {
          ws.close();
          clearTimeout(timeout);
          clearInterval(checkReady);
          resolve();
        };
        ws.onerror = () => {
          // Server not ready yet, will retry
        };
      } catch (e) {
        // Server not ready yet, will retry
      }
    }, 200);
  });

  pass("Server started and listening on port " + TEST_PORT);
  return proc;
}

// Helper to stop the server gracefully
async function stopServer(proc: Subprocess, signal: "SIGTERM" | "SIGINT" = "SIGTERM"): Promise<boolean> {
  const startTime = Date.now();
  
  proc.kill(signal === "SIGTERM" ? 15 : 2); // SIGTERM=15, SIGINT=2
  
  // Wait for process to exit (max 5 seconds)
  const exitPromise = new Promise<boolean>((resolve) => {
    const checkInterval = setInterval(() => {
      if (!proc.killed) {
        const elapsed = Date.now() - startTime;
        if (elapsed > 5000) {
          clearInterval(checkInterval);
          resolve(false); // Timeout
        }
      } else {
        clearInterval(checkInterval);
        resolve(true); // Exited successfully
      }
    }, 100);
  });

  const exitedInTime = await exitPromise;
  const elapsed = Date.now() - startTime;
  
  if (exitedInTime) {
    pass(`Server shut down gracefully in ${elapsed}ms (< 5000ms)`);
    return true;
  } else {
    fail(`Server did not shut down within 5 seconds (took ${elapsed}ms)`);
    proc.kill(9); // Force kill
    return false;
  }
}

// Helper to send MessagePack message and receive response
async function sendMessage(ws: WebSocket, message: any): Promise<any> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error("Message response timeout after 5 seconds"));
    }, 5000);

    ws.onmessage = (event) => {
      clearTimeout(timeout);
      try {
        const data = new Uint8Array(event.data as ArrayBuffer);
        const decoded = decode(data);
        resolve(decoded);
      } catch (e) {
        reject(new Error(`Failed to decode response: ${e}`));
      }
    };

    ws.onerror = (error) => {
      clearTimeout(timeout);
      reject(error);
    };

    // Encode and send message
    const encoded = encode(message);
    ws.send(encoded);
  });
}

// Test 1: Server executable runs and listens (Requirement 20.1, 20.2)
async function testServerStartup() {
  console.log("\n=== Test 1: Server Startup ===\n");
  
  const proc = await startServer();
  
  // Verify server is listening by connecting
  const ws = new WebSocket(TEST_URL);
  
  await new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error("Connection timeout"));
    }, 5000);

    ws.onopen = () => {
      clearTimeout(timeout);
      pass("WebSocket connection accepted");
      ws.close();
      resolve();
    };

    ws.onerror = (error) => {
      clearTimeout(timeout);
      reject(error);
    };
  });

  await stopServer(proc);
  return proc;
}

// Test 2: StoreSet message stores data (Requirement 20.4)
async function testStoreSet(proc: Subprocess) {
  console.log("\n=== Test 2: StoreSet Operation ===\n");
  
  const ws = new WebSocket(TEST_URL);
  
  await new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error("Connection timeout"));
    }, 5000);

    ws.onopen = async () => {
      clearTimeout(timeout);
      pass("Connected to server");
      
      try {
        // Send StoreSet message
        const storeSetMsg = {
          type: "StoreSet",
          id: 1,
          namespace: "test",
          path: "/user/123",
          value: { name: "Alice", age: 30 },
        };

        console.log("Sending StoreSet message:", JSON.stringify(storeSetMsg));
        const response = await sendMessage(ws, storeSetMsg);
        console.log("Received response:", JSON.stringify(response));

        // Verify success response
        if (response.type === "ok" && response.id === 1) {
          pass("StoreSet returned success response");
        } else {
          fail(`StoreSet returned unexpected response: ${JSON.stringify(response)}`);
        }

        ws.close();
        resolve();
      } catch (e) {
        fail(`StoreSet failed: ${e}`);
        ws.close();
        reject(e);
      }
    };

    ws.onerror = (error) => {
      clearTimeout(timeout);
      reject(error);
    };
  });
}

// Test 3: StoreGet message retrieves data (Requirement 20.5)
async function testStoreGet(proc: Subprocess) {
  console.log("\n=== Test 3: StoreGet Operation ===\n");
  
  const ws = new WebSocket(TEST_URL);
  
  await new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error("Connection timeout"));
    }, 5000);

    ws.onopen = async () => {
      clearTimeout(timeout);
      pass("Connected to server");
      
      try {
        // First, store a value
        const storeSetMsg = {
          type: "StoreSet",
          id: 2,
          namespace: "test",
          path: "/user/456",
          value: { name: "Bob", age: 25 },
        };

        console.log("Sending StoreSet message:", JSON.stringify(storeSetMsg));
        const setResponse = await sendMessage(ws, storeSetMsg);
        console.log("StoreSet response:", JSON.stringify(setResponse));

        if (setResponse.type !== "ok") {
          fail("StoreSet failed, cannot test StoreGet");
          ws.close();
          reject(new Error("StoreSet failed"));
          return;
        }

        // Now retrieve the value
        const storeGetMsg = {
          type: "StoreGet",
          id: 3,
          namespace: "test",
          path: "/user/456",
        };

        console.log("Sending StoreGet message:", JSON.stringify(storeGetMsg));
        const getResponse = await sendMessage(ws, storeGetMsg);
        console.log("StoreGet response:", JSON.stringify(getResponse));

        // Verify value response
        if (getResponse.type === "ok" && getResponse.id === 3 && getResponse.value) {
          pass("StoreGet returned value response");
          
          // Verify the value matches what we stored
          const value = getResponse.value;
          if (value.name === "Bob" && value.age === 25) {
            pass("Retrieved value matches stored value");
          } else {
            fail(`Retrieved value does not match: ${JSON.stringify(value)}`);
          }
        } else {
          fail(`StoreGet returned unexpected response: ${JSON.stringify(getResponse)}`);
        }

        ws.close();
        resolve();
      } catch (e) {
        fail(`StoreGet failed: ${e}`);
        ws.close();
        reject(e);
      }
    };

    ws.onerror = (error) => {
      clearTimeout(timeout);
      reject(error);
    };
  });
}

// Test 4: Data persistence across restarts (Requirement 20.6, 20.7)
async function testDataPersistence(proc: Subprocess) {
  console.log("\n=== Test 4: Data Persistence ===\n");
  
  // First, store some data
  let ws = new WebSocket(TEST_URL);
  
  await new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error("Connection timeout"));
    }, 5000);

    ws.onopen = async () => {
      clearTimeout(timeout);
      
      try {
        const storeSetMsg = {
          type: "StoreSet",
          id: 4,
          namespace: "test",
          path: "/persistent/data",
          value: { message: "This should persist" },
        };

        console.log("Storing data before restart:", JSON.stringify(storeSetMsg));
        const response = await sendMessage(ws, storeSetMsg);
        
        if (response.type === "ok") {
          pass("Data stored successfully");
        } else {
          fail("Failed to store data");
        }

        ws.close();
        resolve();
      } catch (e) {
        fail(`Failed to store data: ${e}`);
        ws.close();
        reject(e);
      }
    };

    ws.onerror = (error) => {
      clearTimeout(timeout);
      reject(error);
    };
  });

  // Stop the server
  console.log("\nStopping server...");
  await stopServer(proc);

  // Wait a moment
  await new Promise((resolve) => setTimeout(resolve, 1000));

  // Restart the server
  console.log("\nRestarting server...");
  const newProc = await startServer();

  // Retrieve the data
  ws = new WebSocket(TEST_URL);
  
  await new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error("Connection timeout"));
    }, 5000);

    ws.onopen = async () => {
      clearTimeout(timeout);
      
      try {
        const storeGetMsg = {
          type: "StoreGet",
          id: 5,
          namespace: "test",
          path: "/persistent/data",
        };

        console.log("Retrieving data after restart:", JSON.stringify(storeGetMsg));
        const response = await sendMessage(ws, storeGetMsg);
        console.log("Retrieved response:", JSON.stringify(response));

        if (response.type === "ok" && response.value) {
          const value = response.value;
          if (value.message === "This should persist") {
            pass("Data persisted across server restart");
          } else {
            fail(`Data changed after restart: ${JSON.stringify(value)}`);
          }
        } else {
          fail("Data not found after restart");
        }

        ws.close();
        resolve();
      } catch (e) {
        fail(`Failed to retrieve data after restart: ${e}`);
        ws.close();
        reject(e);
      }
    };

    ws.onerror = (error) => {
      clearTimeout(timeout);
      reject(error);
    };
  });

  return newProc;
}

// Test 5: Graceful shutdown with SIGTERM (Requirement 20.8)
async function testGracefulShutdown(proc: Subprocess) {
  console.log("\n=== Test 5: Graceful Shutdown ===\n");
  
  // Connect a client
  const ws = new WebSocket(TEST_URL);
  
  await new Promise<void>((resolve) => {
    ws.onopen = () => {
      pass("Client connected before shutdown");
      resolve();
    };
  });

  // Send SIGTERM and verify shutdown within 5 seconds
  const shutdownSuccess = await stopServer(proc, "SIGTERM");
  
  if (!shutdownSuccess) {
    fail("Server did not shut down gracefully within 5 seconds");
  }

  // Verify connection was closed
  await new Promise<void>((resolve) => {
    ws.onclose = () => {
      pass("Client connection closed during shutdown");
      resolve();
    };
    
    // If connection is already closed
    if (ws.readyState === WebSocket.CLOSED) {
      pass("Client connection closed during shutdown");
      resolve();
    }
  });
}

// Main test runner
async function runAllTests() {
  console.log("\n╔════════════════════════════════════════════════════════╗");
  console.log("║   ZyncBase Server Integration Tests                   ║");
  console.log("╚════════════════════════════════════════════════════════╝\n");

  try {
    // Setup
    console.log("Setting up test environment...");
    await cleanupTestData();
    await createTestConfig();
    pass("Test environment ready");

    // Run tests
    let proc = await testServerStartup();
    
    // Start fresh server for remaining tests
    proc = await startServer();
    
    await testStoreSet(proc);
    await testStoreGet(proc);
    
    // Test persistence (stops and restarts server)
    proc = await testDataPersistence(proc);
    
    // Test graceful shutdown (stops server)
    await testGracefulShutdown(proc);

    // Cleanup
    console.log("\nCleaning up test environment...");
    await cleanupTestData();
    pass("Test environment cleaned up");

    // Summary
    console.log("\n╔════════════════════════════════════════════════════════╗");
    console.log("║   Test Summary                                         ║");
    console.log("╚════════════════════════════════════════════════════════╝\n");
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
    fail(`Test suite failed with error: ${error}`);
    console.log("\n╔════════════════════════════════════════════════════════╗");
    console.log("║   Test Summary                                         ║");
    console.log("╚════════════════════════════════════════════════════════╝\n");
    console.log(`Tests passed: ${testsPassed}`);
    console.log(`Tests failed: ${testsFailed + 1}`);
    console.log("\n✗ Integration test suite failed\n");
    
    // Cleanup on error
    try {
      await cleanupTestData();
    } catch (e) {
      // Ignore cleanup errors
    }
    
    process.exit(1);
  }
}

// Run tests
runAllTests();
