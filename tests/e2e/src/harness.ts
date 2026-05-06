import * as fs from "node:fs";
import * as net from "node:net";
import * as path from "node:path";
import { format } from "node:util";

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

export type E2ETestContext = {
	artifactDir: string;
	dataDir: string;
	port: number;
	artifactPath: (...parts: string[]) => string;
	dataPath: (...parts: string[]) => string;
	schemaPath: (fileName: string) => string;
};

export type ServerOptions = {
	schemaPath: string;
	dataDir: string;
	configName?: string;
};

export type ServerHandle = {
	port: number;
	configPath: string;
	dataDir: string;
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

function clearCapturedLogs() {
	capturedConsoleLogs.length = 0;
	capturedServerLogs.length = 0;
}

function printCapturedLogs() {
	if (VERBOSE) return;

	if (capturedConsoleLogs.length > 0) {
		status("\n--- captured e2e console.log ---");
		for (const line of capturedConsoleLogs) status(line);
	}
	if (capturedServerLogs.length > 0) {
		status("\n--- captured server logs ---");
		for (const line of capturedServerLogs) status(line);
	}
	if (
		capturedConsoleLogs.length === 0 &&
		capturedServerLogs.length === 0 &&
		!CAPTURE_LOGS
	) {
		status(
			"Suppressed logs were discarded. Re-run with --verbose or --capture-logs to see them.",
		);
	}
}

function withConsoleCapture<T>(callback: () => Promise<T>): Promise<T> {
	if (VERBOSE) return callback();

	const previousLog = console.log;
	const previousWarn = console.warn;
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

	return callback().finally(() => {
		console.log = previousLog;
		console.warn = previousWarn;
	});
}

function ensureDir(dir: string) {
	fs.mkdirSync(dir, { recursive: true });
}

function removeDir(dir: string) {
	if (fs.existsSync(dir)) {
		fs.rmSync(dir, { recursive: true, force: true });
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

function slugify(name: string): string {
	const slug = name
		.toLowerCase()
		.replace(/[^a-z0-9]+/g, "-")
		.replace(/^-+|-+$/g, "");
	return slug.length > 0 ? slug : "scenario";
}

async function getFreePort(): Promise<number> {
	return await new Promise((resolve, reject) => {
		const server = net.createServer();
		server.on("error", reject);
		server.listen(0, "127.0.0.1", () => {
			const address = server.address();
			if (typeof address !== "object" || address === null) {
				server.close(() => reject(new Error("Failed to allocate a free port")));
				return;
			}
			const port = address.port;
			server.close((err) => {
				if (err) reject(err);
				else resolve(port);
			});
		});
	});
}

async function waitForPort(port: number, retries = 50): Promise<void> {
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

async function startServer(
	configPath: string,
	port: number,
): Promise<RunningServer> {
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
		await waitForPort(port);
		return server;
	} catch (err) {
		serverProcess.kill();
		await serverProcess.exited.catch(() => {});
		await collectServerLogs(server);
		throw err;
	}
}

async function stopServer(server: RunningServer) {
	server.process.kill();
	await server.process.exited.catch(() => {});
	await collectServerLogs(server);
}

export function buildServerIfNeeded() {
	if (!shouldBuildServer()) {
		log("Server binary up to date, skipping build.");
		return;
	}

	log("Building ZyncBase server (ReleaseFast)...");
	const start = Date.now();
	const result = Bun.spawnSync(["zig", "build", "-Doptimize=ReleaseFast"], {
		stdio: VERBOSE
			? ["inherit", "inherit", "inherit"]
			: ["ignore", "pipe", "pipe"],
	});
	if (result.exitCode !== 0) {
		printBuildFailure(result);
		throw new Error("Failed to build ZyncBase server");
	}
	const duration = ((Date.now() - start) / 1000).toFixed(1);
	log(`Build finished in ${duration}s.`);
}

export function resetE2ERoots() {
	removeDir(DATA_DIR);
	removeDir(ARTIFACT_DIR);
	ensureDir(DATA_DIR);
	ensureDir(ARTIFACT_DIR);
}

export function cleanupE2EArtifacts() {
	removeDir(ARTIFACT_DIR);
}

export async function createE2ETestContext(
	name: string,
): Promise<E2ETestContext> {
	const slug = `${slugify(name)}-${crypto.randomUUID().slice(0, 8)}`;
	const artifactDir = path.join(ARTIFACT_DIR, slug);
	const dataDir = path.join(DATA_DIR, slug);
	ensureDir(artifactDir);
	ensureDir(dataDir);
	const port = await getFreePort();

	return {
		artifactDir,
		dataDir,
		port,
		artifactPath: (...parts: string[]) => path.join(artifactDir, ...parts),
		dataPath: (...parts: string[]) => path.join(dataDir, ...parts),
		schemaPath: (fileName: string) => path.join("tests/e2e", fileName),
	};
}

export async function runE2ETest(
	name: string,
	callback: (ctx: E2ETestContext) => Promise<void>,
) {
	clearCapturedLogs();
	log(`--- ${name} ---`);
	const ctx = await createE2ETestContext(name);

	try {
		await withConsoleCapture(() => callback(ctx));
	} catch (err) {
		printCapturedLogs();
		throw err;
	}
}

export async function withServer<T>(
	ctx: E2ETestContext,
	options: ServerOptions,
	callback: (server: ServerHandle) => Promise<T>,
): Promise<T> {
	ensureDir(options.dataDir);
	const configPath = ctx.artifactPath(
		options.configName ?? "zyncbase-config.json",
	);
	fs.writeFileSync(
		configPath,
		JSON.stringify({
			server: { port: ctx.port },
			dataDir: options.dataDir,
			schema: options.schemaPath,
		}),
	);

	log(`Starting server with ${options.schemaPath} on port ${ctx.port}...`);
	const server = await startServer(configPath, ctx.port);
	try {
		return await callback({
			port: ctx.port,
			configPath,
			dataDir: options.dataDir,
		});
	} finally {
		await stopServer(server);
	}
}
