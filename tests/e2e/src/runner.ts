import { spawn, spawnSync, ChildProcess } from "child_process";
import { ZyncBaseClient } from "./client";
import * as fs from "fs";
import * as path from "path";

const PORT = 3000;
const DATA_DIR = "tests/e2e/data";
const SERVER_BIN = "./zig-out/bin/zyncbase";

function getLatestSourceTimestamp(dirs: string[]): number {
  let latest = 0;
  for (const dir of dirs) {
    const fullDir = path.resolve(dir);
    if (!fs.existsSync(fullDir)) continue;
    
    const scan = (d: string) => {
      const entries = fs.readdirSync(d, { withFileTypes: true });
      for (const entry of entries) {
        const fullPath = path.join(d, entry.name);
        if (entry.isDirectory()) {
          scan(fullPath);
        } else if (entry.name.endsWith(".zig") || entry.name.endsWith(".c") || entry.name.endsWith(".cpp") || entry.name.endsWith(".h")) {
          const stats = fs.statSync(fullPath);
          if (stats.mtimeMs > latest) {
            latest = stats.mtimeMs;
          }
        }
      }
    };
    scan(fullDir);
  }
  return latest;
}

function checkBuild() {
  const forceBuild = process.argv.includes("--force-build");
  const latestSource = getLatestSourceTimestamp(["src", "vendor"]);
  const binaryStats = fs.existsSync(SERVER_BIN) ? fs.statSync(SERVER_BIN) : null;

  if (forceBuild || !binaryStats || latestSource > binaryStats.mtimeMs) {
    const timeStr = new Date().toLocaleTimeString('en-GB', { hour12: false });
    console.log(`[${timeStr}] Building ZyncBase server (ReleaseFast)...`);
    const start = Date.now();
    const result = spawnSync("zig", ["build", "-Doptimize=ReleaseFast"], { stdio: "inherit" });
    if (result.status !== 0) {
      console.error("Build failed");
      process.exit(1);
    }
    const duration = ((Date.now() - start) / 1000).toFixed(1);
    console.log(`Build finished in ${duration}s.`);
  } else {
    console.log("Server binary up to date, skipping build.");
  }
}

async function wait_for_port(port: number, retries = 50): Promise<void> {
  for (let i = 0; i < retries; i++) {
    try {
      const socket = new (require("net").Socket)();
      await new Promise<void>((resolve, reject) => {
        socket.setTimeout(100);
        socket.on("connect", () => {
          socket.destroy();
          resolve();
        });
        socket.on("error", (err: any) => {
          socket.destroy();
          reject(err);
        });
        socket.on("timeout", () => {
          socket.destroy();
          reject(new Error("timeout"));
        });
        socket.connect(port, "127.0.0.1");
      });
      return;
    } catch (err) {
      await new Promise(resolve => setTimeout(resolve, 100));
    }
  }
  throw new Error(`Timeout waiting for port ${port}`);
}

async function start_server(configPath: string): Promise<ChildProcess> {
  // Kill any process on the port first to avoid stale connections
  try {
    const { execSync } = require("child_process");
    execSync(`lsof -ti:${PORT} | xargs kill -9 2>/dev/null || true`);
  } catch (e) {}

  const server = spawn(SERVER_BIN, ["--config", configPath], {
    stdio: "inherit",
    cwd: process.cwd(),
  });
  await wait_for_port(PORT);
  // Small safety sleep for macOS process readiness
  await new Promise(resolve => setTimeout(resolve, 500));
  return server;
}

async function stop_server(server: ChildProcess) {
  server.kill();
  await new Promise(resolve => server.on("exit", resolve));
}

import { run as runSync } from "./test-sync";
import { run as runErrors } from "./test-errors";
import { run as runPersistence } from "./test-persistence";

async function run_scenario_sync_and_errors() {
  console.log("--- Bi-directional Sync ---");
  const schemaPath = "tests/e2e/schema-sync.json";
  const dataDir = path.join(DATA_DIR, "sync");
  const config = { server: { port: PORT }, dataDir: dataDir, schema: schemaPath };
  const configPath = "test-artifacts/zyncbase-config-sync.json";
  fs.writeFileSync(configPath, JSON.stringify(config));
  console.log(`Starting server with ${schemaPath}...`);
  const server = await start_server(configPath);
  try {
    await runSync(PORT);
    
    console.log("--- Error Reporting ---");
    await runErrors(PORT);
  } finally {
    await stop_server(server);
  }
}

async function run_scenario_persistence() {
  console.log("--- Persistence ---");
  const schemaPath = "tests/e2e/schema-persistence.json";
  const config = { server: { port: PORT }, dataDir: DATA_DIR, schema: schemaPath };
  const configPath = "test-artifacts/zyncbase-config.json";
  fs.writeFileSync(configPath, JSON.stringify(config));

  // Step 1: Set
  let server = await start_server(configPath);
  try {
    await runPersistence("set", PORT);
  } finally {
    await stop_server(server);
  }

  // Step 2: Get
  server = await start_server(configPath);
  try {
    await runPersistence("get", PORT);
  } finally {
    await stop_server(server);
  }
  console.log("Scenario 2 passed.");
}

async function main() {
  const timeStr = new Date().toLocaleTimeString('en-GB', { hour12: false });
  console.log(`[${timeStr}] === ZyncBase E2E Test Suite (Optimized) ===`);

  checkBuild();

  if (fs.existsSync(DATA_DIR)) fs.rmSync(DATA_DIR, { recursive: true });
  fs.mkdirSync(DATA_DIR, { recursive: true });

  try {
    console.log("Running consolidated E2E suite...");
    await run_scenario_sync_and_errors();
    await run_scenario_persistence();
    console.log("=== All E2E Tests Passed! ===");
  } catch (err) {
    console.error("E2E Test Suite Failed:", err);
    process.exit(1);
  }
}

main();
