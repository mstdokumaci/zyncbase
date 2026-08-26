import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";

import { buildServerIfNeeded } from "../e2e/src/harness";

const profiles = [
	"connections",
	"store-accepted",
	"store-committed",
	"store-identical-filter",
	"presence-user",
	"presence-shared",
] as const;
type Profile = (typeof profiles)[number];

const args = process.argv.slice(2);
const smoke = takeFlag("--smoke");
const profile = takeOption("--profile", "connections") as Profile;
if (!profiles.includes(profile)) {
	throw new Error(`--profile must be one of ${profiles.join(", ")}`);
}

const envOptions: Record<string, string> = {};
for (const [flag, name] of [
	["--clients", "CLIENTS"],
	["--writers", "WRITERS"],
	["--subscribers", "SUBSCRIBERS"],
	["--rate", "RATE"],
	["--sockets-per-vu", "SOCKETS_PER_VU"],
	["--setup", "SETUP_SECONDS"],
	["--connect-ramp", "CONNECT_RAMP_SECONDS"],
	["--barrier", "BARRIER_SECONDS"],
	["--warmup", "WARMUP_SECONDS"],
	["--duration", "DURATION_SECONDS"],
	["--cooldown", "COOLDOWN_SECONDS"],
	["--probe-rate", "PROBE_RATE"],
	["--max-inflight", "MAX_INFLIGHT"],
	["--max-event-loop-lag", "MAX_EVENT_LOOP_LAG_MS"],
] as const) {
	const value = takeOption(flag);
	if (value !== undefined) {
		envOptions[name] =
			flag === "--connect-ramp"
				? nonNegativeInteger(flag, value)
				: positiveInteger(flag, value);
	}
}
if (args.length > 0) throw new Error(`Unknown arguments: ${args.join(" ")}`);

const k6 = Bun.which("k6");
if (!k6) throw new Error("k6 was not found in PATH");
const k6Version = commandText([k6, "version"]);
const fanout =
	profile === "store-identical-filter" || profile.startsWith("presence-");
const rate = Number(envOptions.RATE ?? (fanout ? 100 : 10_000));
const expectedConnections = fanout
	? Number(envOptions.SUBSCRIBERS ?? (smoke ? 3 : 5_000)) +
		Number(
			envOptions.WRITERS ?? (profile === "presence-shared" ? 1 : smoke ? 2 : 32),
		)
	: Number(envOptions.CLIENTS ?? (smoke ? 5 : 5_000));
const openFileLimit = Math.max(65_536, expectedConnections + 4_096);
const expectedTestSeconds =
	Number(envOptions.SETUP_SECONDS ?? (smoke ? 4 : fanout ? 45 : 20)) +
	Number(envOptions.BARRIER_SECONDS ?? 1) +
	Number(envOptions.WARMUP_SECONDS ?? (smoke ? 1 : 10)) +
	Number(envOptions.DURATION_SECONDS ?? (smoke ? 3 : 30)) +
	Number(envOptions.COOLDOWN_SECONDS ?? (smoke ? 3 : 10));
const hardTimeoutSeconds = expectedTestSeconds + 45;
const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
const artifactDir = path.resolve("test-artifacts/load", `${timestamp}-${profile}${smoke ? "-smoke" : ""}`);
const dataDir = path.join(artifactDir, "data");
const configPath = path.join(artifactDir, "server-config.json");
const serverLogPath = path.join(artifactDir, "server.log");
const bundlePath = path.join(artifactDir, "zyncbase.k6.js");
const summaryPath = path.join(artifactDir, "k6-summary.json");
const resourcesPath = path.join(artifactDir, "resources.json");
const runPath = path.join(artifactDir, "run.json");

fs.mkdirSync(dataDir, { recursive: true });
buildServerIfNeeded();
const port = await freePort();
fs.writeFileSync(
	configPath,
	JSON.stringify(
		{
			server: { host: "127.0.0.1", port },
			dataDir,
			schema: path.resolve("tests/load/schema.json"),
			authorization: path.resolve("tests/e2e/auth-allow-all.json"),
			authentication: {
				anonymous: { enabled: true },
				ticket: { secret: "e2e-test-ticket-secret-32bytes!" },
			},
			security: {
				maxConnections: Math.max(100_000, expectedConnections + 1_000),
				maxMessagesPerSecond: Math.max(100_000, rate * 2),
			},
			logging: { level: "error", format: "json" },
		},
		null,
		2,
	),
);

const bundle = Bun.spawnSync(
	[
		process.execPath,
		"build",
		"tests/load/zyncbase.k6.ts",
		"--target=browser",
		"--external=k6",
		"--external=k6/*",
		`--outfile=${bundlePath}`,
	],
	{ stdout: "inherit", stderr: "inherit" },
);
if (bundle.exitCode !== 0) throw new Error("Failed to bundle the k6 test");

const serverLog = fs.openSync(serverLogPath, "w");
const server = Bun.spawn(
	withOpenFileLimit([
		path.resolve("zig-out/bin/zyncbase"),
		"--config",
		configPath,
	]),
	{ stdio: ["ignore", serverLog, serverLog] },
);
let k6Process: Bun.Subprocess | undefined;
let interrupted = false;
const signalHandler = (signal: NodeJS.Signals) => {
	interrupted = true;
	k6Process?.kill("SIGKILL");
	server.kill(signal);
};
process.on("SIGINT", signalHandler);
process.on("SIGTERM", signalHandler);

const startedAt = new Date();
const resources: ResourceSample[] = [];
let sampler: ReturnType<typeof setInterval> | undefined;
let exitCode = 1;
let timedOut = false;
try {
	await waitForPort(port, server);
	console.log(`${smoke ? "Smoke" : "Benchmark"}: ${profile}`);
	console.log(`Server: ws://127.0.0.1:${port}`);
	console.log(`Artifacts: ${artifactDir}`);

	k6Process = Bun.spawn(withOpenFileLimit([k6, "run", bundlePath]), {
		stdio: ["inherit", "inherit", "inherit"],
		env: {
			...process.env,
			K6_NO_USAGE_REPORT: "true",
			PROFILE: profile,
			SMOKE: smoke ? "1" : "0",
			WS_URL: `ws://127.0.0.1:${port}`,
			RESULT_PATH: summaryPath,
			...envOptions,
		},
	});
	const sample = () => {
		resources.push({
			atMs: Date.now() - startedAt.getTime(),
			server: processResources(server.pid),
			k6: k6Process ? processResources(k6Process.pid) : null,
		});
	};
	sample();
	sampler = setInterval(sample, 1_000);
	exitCode = await new Promise<number>((resolve) => {
		const timer = setTimeout(() => {
			timedOut = true;
			k6Process?.kill("SIGKILL");
		}, hardTimeoutSeconds * 1_000);
		k6Process?.exited.then((code) => {
			clearTimeout(timer);
			resolve(timedOut ? 124 : code);
		});
	});
} finally {
	if (sampler) clearInterval(sampler);
	server.kill("SIGTERM");
	await server.exited.catch(() => {});
	fs.closeSync(serverLog);
	process.off("SIGINT", signalHandler);
	process.off("SIGTERM", signalHandler);
	fs.writeFileSync(resourcesPath, JSON.stringify(resources, null, 2));
	fs.writeFileSync(
		runPath,
		JSON.stringify(
			{
				profile,
				smoke,
				benchmarkEligible: !smoke && exitCode === 0,
				startedAt: startedAt.toISOString(),
				finishedAt: new Date().toISOString(),
				exitCode,
				interrupted,
				timedOut,
				k6Version,
				openFileLimit,
				hardTimeoutSeconds,
				gitCommit: commandText(["git", "rev-parse", "HEAD"]),
				host: {
					platform: process.platform,
					arch: process.arch,
					cpus: os.cpus().length,
					memoryBytes: os.totalmem(),
				},
				options: envOptions,
			},
			null,
			2,
		),
	);
}

if (exitCode !== 0) {
	console.error(`k6 failed with exit code ${exitCode}; artifacts kept at ${artifactDir}`);
	process.exit(exitCode);
}
console.log(`Completed successfully; artifacts kept at ${artifactDir}`);

interface ProcessResources {
	cpuPercent: number;
	rssBytes: number;
}

interface ResourceSample {
	atMs: number;
	server: ProcessResources | null;
	k6: ProcessResources | null;
}

function takeFlag(flag: string): boolean {
	const index = args.indexOf(flag);
	if (index < 0) return false;
	args.splice(index, 1);
	return true;
}

function takeOption(flag: string, fallback?: string): string | undefined {
	const index = args.indexOf(flag);
	if (index < 0) return fallback;
	const value = args[index + 1];
	if (!value || value.startsWith("--")) throw new Error(`${flag} requires a value`);
	args.splice(index, 2);
	return value;
}

function positiveInteger(flag: string, value: string): string {
	const number = Number(value);
	if (!Number.isInteger(number) || number <= 0) {
		throw new Error(`${flag} must be a positive integer`);
	}
	return String(number);
}

function nonNegativeInteger(flag: string, value: string): string {
	const number = Number(value);
	if (!Number.isInteger(number) || number < 0) {
		throw new Error(`${flag} must be a non-negative integer`);
	}
	return String(number);
}

function commandText(command: string[]): string {
	const result = Bun.spawnSync(command, { stdout: "pipe", stderr: "pipe" });
	if (result.exitCode !== 0) return "unknown";
	return new TextDecoder().decode(result.stdout).trim();
}

function withOpenFileLimit(command: string[]): string[] {
	if (process.platform === "win32") return command;
	return [
		"/bin/sh",
		"-c",
		'ulimit -n "$1" || exit $?; shift; exec "$@"',
		"zyncbase-load",
		String(openFileLimit),
		...command,
	];
}

function processResources(pid: number): ProcessResources | null {
	const result = Bun.spawnSync(["ps", "-o", "%cpu=,rss=", "-p", String(pid)], {
		stdout: "pipe",
		stderr: "ignore",
	});
	if (result.exitCode !== 0) return null;
	const values = new TextDecoder().decode(result.stdout).trim().split(/\s+/);
	if (values.length !== 2) return null;
	return { cpuPercent: Number(values[0]), rssBytes: Number(values[1]) * 1_024 };
}

async function freePort(): Promise<number> {
	return await new Promise((resolve, reject) => {
		const server = net.createServer();
		server.on("error", reject);
		server.listen(0, "127.0.0.1", () => {
			const address = server.address();
			if (!address || typeof address === "string") {
				server.close(() => reject(new Error("Failed to allocate a port")));
				return;
			}
			server.close((error) => (error ? reject(error) : resolve(address.port)));
		});
	});
}

async function waitForPort(port: number, server: Bun.Subprocess): Promise<void> {
	for (let attempt = 0; attempt < 100; attempt++) {
		if (server.exitCode !== null) throw new Error(`Server exited with ${server.exitCode}`);
		try {
			await new Promise<void>((resolve, reject) => {
				const socket = net.createConnection({ host: "127.0.0.1", port });
				socket.setTimeout(100);
				socket.once("connect", () => {
					socket.destroy();
					resolve();
				});
				socket.once("error", reject);
				socket.once("timeout", () => reject(new Error("timeout")));
			});
			return;
		} catch {
			await Bun.sleep(100);
		}
	}
	throw new Error(`Timed out waiting for server on port ${port}`);
}
