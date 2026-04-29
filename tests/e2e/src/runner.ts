import * as fs from "node:fs";
import * as path from "node:path";
import { format } from "node:util";

const PORT = 3000;
const DATA_DIR = "tests/e2e/data";
const ARTIFACT_DIR = "test-artifacts/e2e";
const SERVER_BIN = "./zig-out/bin/zyncbase";
const VERBOSE =
	process.argv.includes("--verbose") ||
	process.env.ZYNCBASE_TEST_VERBOSE === "1";
const CAPTURE_LOGS =
	!VERBOSE &&
	(process.argv.includes("--capture-logs") ||
		process.env.ZYNCBASE_TEST_CAPTURE_LOGS === "1");
const MAX_CAPTURED_LOG_LINES = 1000;
const originalConsoleLog = console.log.bind(console);
const capturedConsoleLogs: string[] = [];
const capturedServerLogs: string[] = [];

type RunningServer = {
	process: Bun.Subprocess;
	stdoutText: Promise<string>;
	stderrText: Promise<string>;
	configPath: string;
};

type CapturedProcessOutput = {
	stdout?: unknown;
	stderr?: unknown;
};

function captureLines(target: string[], text: string) {
	if (target.length > MAX_CAPTURED_LOG_LINES) return;
	for (const line of text.split(/\r?\n/)) {
		if (line.length === 0) continue;
		if (target.length < MAX_CAPTURED_LOG_LINES) {
			target.push(line);
		} else {
			target.push("... captured logs truncated ...");
			break;
		}
	}
}

if (!VERBOSE) {
	console.log = (...args: unknown[]) => {
		if (CAPTURE_LOGS && capturedConsoleLogs.length <= MAX_CAPTURED_LOG_LINES) {
			captureLines(capturedConsoleLogs, format(...args));
		}
	};
	console.warn = (...args: unknown[]) => {
		if (CAPTURE_LOGS && capturedConsoleLogs.length <= MAX_CAPTURED_LOG_LINES) {
			captureLines(capturedConsoleLogs, format(...args));
		}
	};
}

function log(message: string) {
	const timeStr = new Date().toLocaleTimeString("en-GB", { hour12: false });
	originalConsoleLog(`[${timeStr}] ${message}`);
}

function status(message: string) {
	originalConsoleLog(message);
}

function decodeOutput(output: unknown): string {
	if (output == null) return "";
	if (typeof output === "string") return output;
	if (output instanceof Uint8Array) return new TextDecoder().decode(output);
	return String(output);
}

function countNewlines(text: string): number {
	let count = 0;
	for (const ch of text) {
		if (ch === "\n") count++;
	}
	return count;
}

async function readStream(
	stream: ReadableStream<Uint8Array> | null | undefined,
): Promise<string> {
	if (!stream) return "";
	const reader = stream.getReader();
	const decoder = new TextDecoder();
	const parts: string[] = [];
	let lineCount = 0;
	try {
		while (true) {
			const { done, value } = await reader.read();
			if (done) break;
			const text = decoder.decode(value, { stream: true });
			lineCount += countNewlines(text);
			parts.push(text);
			if (lineCount >= MAX_CAPTURED_LOG_LINES) {
				reader.cancel().catch(() => {});
				break;
			}
		}
		return parts.join("");
	} catch (err) {
		return `failed to read process output: ${String(err)}`;
	} finally {
		reader.releaseLock();
	}
}

async function collectServerLogs(server: RunningServer) {
	if (VERBOSE) return;
	const [stdout, stderr] = await Promise.all([
		server.stdoutText,
		server.stderrText,
	]);
	if (stdout.trim().length > 0) {
		captureLines(
			capturedServerLogs,
			`--- server stdout (${server.configPath}) ---\n${stdout}`,
		);
	}
	if (stderr.trim().length > 0) {
		captureLines(
			capturedServerLogs,
			`--- server stderr (${server.configPath}) ---\n${stderr}`,
		);
	}
}

function printCapturedLogs() {
	if (!CAPTURE_LOGS && capturedServerLogs.length === 0) {
		status(
			"Suppressed logs were discarded. Re-run with --verbose to stream them.",
		);
		return;
	}
	if (capturedConsoleLogs.length > 0) {
		status("\n--- captured e2e console.log ---");
		for (const line of capturedConsoleLogs) status(line);
	}
	if (capturedServerLogs.length > 0) {
		status("\n--- captured server logs ---");
		for (const line of capturedServerLogs) status(line);
	}
}

function ensureArtifactDir() {
	if (!fs.existsSync(ARTIFACT_DIR)) {
		fs.mkdirSync(ARTIFACT_DIR, { recursive: true });
	}
}

function cleanupArtifactDir() {
	if (fs.existsSync(ARTIFACT_DIR)) {
		fs.rmSync(ARTIFACT_DIR, { recursive: true, force: true });
	}
}

function isRuntimeSourceFile(fileName: string): boolean {
	if (
		fileName.endsWith("_test.zig") ||
		fileName.endsWith("_property_test.zig") ||
		fileName.endsWith("_test_helpers.zig") ||
		fileName === "test_all.zig" ||
		fileName === "timed_test_runner.zig"
	) {
		return false;
	}

	return (
		fileName.endsWith(".zig") ||
		fileName.endsWith(".c") ||
		fileName.endsWith(".cpp") ||
		fileName.endsWith(".h")
	);
}

function scanSourceDir(d: string, latest: number): number {
	let currentLatest = latest;
	const entries = fs.readdirSync(d, { withFileTypes: true });
	for (const entry of entries) {
		const fullPath = path.join(d, entry.name);
		if (entry.isDirectory()) {
			currentLatest = scanSourceDir(fullPath, currentLatest);
		} else if (isRuntimeSourceFile(entry.name)) {
			const stats = fs.statSync(fullPath);
			if (stats.mtimeMs > currentLatest) {
				currentLatest = stats.mtimeMs;
			}
		}
	}
	return currentLatest;
}

function getLatestSourceTimestamp(dirs: string[]): number {
	let latest = 0;
	for (const dir of dirs) {
		const fullDir = path.resolve(dir);
		if (!fs.existsSync(fullDir)) continue;
		latest = scanSourceDir(fullDir, latest);
	}
	return latest;
}

function shouldBuildServer(): boolean {
	const forceBuild = process.argv.includes("--force-build");
	if (forceBuild) return true;

	const latestSource = getLatestSourceTimestamp(["src", "vendor"]);
	const binaryStats = fs.existsSync(SERVER_BIN)
		? fs.statSync(SERVER_BIN)
		: null;

	return !binaryStats || latestSource > binaryStats.mtimeMs;
}

function printBuildFailure(result: CapturedProcessOutput) {
	console.error("Build failed");
	if (VERBOSE) return;

	const stdout = decodeOutput(result.stdout);
	const stderr = decodeOutput(result.stderr);
	if (stdout.trim().length > 0) status(stdout);
	if (stderr.trim().length > 0) console.error(stderr);
}

function checkBuild() {
	if (!shouldBuildServer()) {
		log("Server binary up to date, skipping build.");
		return;
	}

	log(`Building ZyncBase server (ReleaseFast)...`);
	const start = Date.now();
	const result = Bun.spawnSync(["zig", "build", "-Doptimize=ReleaseFast"], {
		stdio: VERBOSE
			? ["inherit", "inherit", "inherit"]
			: ["ignore", "pipe", "pipe"],
	});
	if (result.exitCode !== 0) {
		printBuildFailure(result);
		process.exit(1);
	}
	const duration = ((Date.now() - start) / 1000).toFixed(1);
	log(`Build finished in ${duration}s.`);
}

async function wait_for_port(port: number, retries = 50): Promise<void> {
	for (let i = 0; i < retries; i++) {
		try {
			await new Promise<void>((resolve, reject) => {
				const timeout = setTimeout(() => {
					reject(new Error("timeout"));
				}, 100);
				Bun.connect({
					hostname: "127.0.0.1",
					port,
					socket: {
						open(socket) {
							clearTimeout(timeout);
							socket.end();
							resolve();
						},
						data() {},
						error(_socket, err) {
							clearTimeout(timeout);
							reject(err);
						},
					},
				}).catch((err) => {
					clearTimeout(timeout);
					reject(err);
				});
			});
			return;
		} catch (_err) {
			await new Promise((resolve) => setTimeout(resolve, 100));
		}
	}
	throw new Error(`Timeout waiting for port ${port}`);
}

async function start_server(configPath: string): Promise<RunningServer> {
	// Kill any process on the port first to avoid stale connections
	try {
		Bun.spawnSync([
			"sh",
			"-c",
			`lsof -ti:${PORT} | xargs kill -9 2>/dev/null || true`,
		]);
	} catch (_e) {}

	const serverProcess = Bun.spawn([SERVER_BIN, "--config", configPath], {
		stdio: VERBOSE
			? ["inherit", "inherit", "inherit"]
			: ["ignore", "pipe", "pipe"],
		cwd: process.cwd(),
	});
	const server: RunningServer = {
		process: serverProcess,
		stdoutText: VERBOSE
			? Promise.resolve("")
			: readStream(serverProcess.stdout),
		stderrText: VERBOSE
			? Promise.resolve("")
			: readStream(serverProcess.stderr),
		configPath,
	};
	try {
		await wait_for_port(PORT);
		await new Promise((resolve) => setTimeout(resolve, 500));
		return server;
	} catch (err) {
		serverProcess.kill();
		await serverProcess.exited.catch(() => {});
		await collectServerLogs(server);
		throw err;
	}
}

async function stop_server(server: RunningServer) {
	server.process.kill();
	await server.process.exited;
	await collectServerLogs(server);
}

import { run as runErrors } from "./test-errors";
import { run as runFilters } from "./test-filters";
import { run as runPersistence } from "./test-persistence";
import { run as runSync } from "./test-sync";

async function run_scenario_sync_and_errors() {
	log("--- Bi-directional Sync ---");
	const schemaPath = "tests/e2e/schema-sync.json";
	const dataDir = path.join(DATA_DIR, "sync");
	const config = {
		server: { port: PORT },
		dataDir: dataDir,
		schema: schemaPath,
	};
	const configPath = path.join(ARTIFACT_DIR, "zyncbase-config-sync.json");
	fs.writeFileSync(configPath, JSON.stringify(config));
	log(`Starting server with ${schemaPath}...`);
	const server = await start_server(configPath);
	try {
		await runSync(PORT);

		log("--- Error Reporting ---");
		await runErrors(PORT);
	} finally {
		await stop_server(server);
	}
}

async function run_scenario_persistence() {
	log("--- Persistence ---");
	const schemaPath = "tests/e2e/schema-persistence.json";
	const config = {
		server: { port: PORT },
		dataDir: DATA_DIR,
		schema: schemaPath,
	};
	const configPath = path.join(ARTIFACT_DIR, "zyncbase-config.json");
	fs.writeFileSync(configPath, JSON.stringify(config));

	// Step 1: Set
	let server = await start_server(configPath);
	try {
		await runPersistence("set", PORT, ARTIFACT_DIR);
	} finally {
		await stop_server(server);
	}

	// Step 2: Get
	server = await start_server(configPath);
	try {
		await runPersistence("get", PORT, ARTIFACT_DIR);
	} finally {
		await stop_server(server);
	}
	console.log("Scenario 2 passed.");
}

async function run_scenario_filters() {
	log("--- Filtered Subscriptions ---");
	const schemaPath = "tests/e2e/schema-filters.json";
	const dataDir = path.join(DATA_DIR, "filters");
	const config = {
		server: { port: PORT },
		dataDir: dataDir,
		schema: schemaPath,
	};
	const configPath = path.join(ARTIFACT_DIR, "zyncbase-config-filters.json");
	fs.writeFileSync(configPath, JSON.stringify(config));
	log(`Starting server with ${schemaPath}...`);
	const server = await start_server(configPath);
	try {
		await runFilters(PORT);
	} finally {
		await stop_server(server);
	}
}

async function main() {
	log("=== ZyncBase E2E Test Suite (Optimized) ===");

	checkBuild();
	ensureArtifactDir();

	if (fs.existsSync(DATA_DIR)) fs.rmSync(DATA_DIR, { recursive: true });
	fs.mkdirSync(DATA_DIR, { recursive: true });

	try {
		log("Running consolidated E2E suite...");
		await run_scenario_sync_and_errors();
		await run_scenario_persistence();
		log("Scenario 2 passed.");
		await run_scenario_filters();
		log("Scenario 3 passed.");
		log("=== All E2E Tests Passed! ===");
	} catch (err) {
		console.error("E2E Test Suite Failed:", err);
		printCapturedLogs();
		process.exit(1);
	} finally {
		cleanupArtifactDir();
	}
}

main();
