import * as fs from "node:fs";

import { type E2ETestContext, SERVER_BIN } from "./harness";

type Spawned = {
	exitCode: number | null;
	signalCode: string | null;
	log: string;
};

type SpawnOptions = {
	/** Log line that means the server is ready to receive the signal. */
	readyMarker: string;
	onReady: (pid: number) => void;
	timeoutMs?: number;
};

// Logged after installSignalHandlers() runs, so it is the earliest externally
// observable point where a SIGTERM must be handled rather than defaulted.
const READY_STARTUP = "Initializing ZyncBase server";
// Logged once listen() returned and the server accepts connections.
const READY_LISTENING = "Server started successfully";
const DEFAULT_TIMEOUT_MS = 15_000;

function writeConfig(ctx: E2ETestContext, name: string): string {
	const configPath = ctx.artifactPath(`${name}.json`);
	const dataDir = ctx.dataPath(name);
	fs.mkdirSync(dataDir, { recursive: true });
	fs.writeFileSync(
		configPath,
		JSON.stringify({
			server: { port: ctx.port },
			dataDir,
			schema: ctx.schemaPath("schema-sync.json"),
			authentication: {
				anonymous: { enabled: true },
				ticket: { secret: "e2e-test-ticket-secret-32bytes!" },
			},
		}),
	);
	return configPath;
}

function withTimeout<T>(
	promise: Promise<T>,
	ms: number,
): Promise<T | "timeout"> {
	return new Promise((resolve) => {
		const timer = setTimeout(() => resolve("timeout"), ms);
		void promise.then((value) => {
			clearTimeout(timer);
			resolve(value);
		});
	});
}

/**
 * Spawn the server, wait for `readyMarker`, signal it, then wait for exit with
 * a bounded timeout so a wedged child cannot hang the suite. The stderr reader
 * is drained to completion before returning so `log` contains the final lines.
 */
async function withSpawnedServer(
	ctx: E2ETestContext,
	name: string,
	options: SpawnOptions,
): Promise<Spawned> {
	const proc = Bun.spawn([SERVER_BIN, "--config", writeConfig(ctx, name)], {
		cwd: process.cwd(),
		stdio: ["ignore", "ignore", "pipe"],
	});

	let log = "";
	let markReady = () => {};
	const ready = new Promise<void>((resolve) => {
		markReady = resolve;
	});
	const reader = proc.stderr.getReader();
	const decoder = new TextDecoder();
	const drained = (async () => {
		for (;;) {
			const { value, done } = await reader.read();
			if (done) return;
			log += decoder.decode(value, { stream: true });
			if (log.includes(options.readyMarker)) markReady();
		}
	})();

	// If the child dies before reaching the marker, fall through so the exit
	// assertions report the real status instead of hanging on `ready`.
	await Promise.race([ready, proc.exited]);

	if (proc.exitCode === null && proc.signalCode === null) {
		try {
			options.onReady(proc.pid);
		} catch {
			// Child vanished between the check and the signal; the exit
			// assertions below report it.
		}
	}

	const outcome = await withTimeout(
		proc.exited.then(() => "exited" as const),
		options.timeoutMs ?? DEFAULT_TIMEOUT_MS,
	);
	if (outcome === "timeout") {
		proc.kill("SIGKILL");
		await proc.exited;
	}

	await drained;
	return { exitCode: proc.exitCode, signalCode: proc.signalCode, log };
}

function assertGraceful(label: string, spawned: Spawned): void {
	if (spawned.exitCode !== 0 || spawned.signalCode !== null) {
		throw new Error(
			`${label}: expected exit code 0, got exit=${spawned.exitCode} signal=${spawned.signalCode}\n${spawned.log}`,
		);
	}
	if (!spawned.log.includes("Graceful shutdown complete")) {
		throw new Error(
			`${label}: graceful shutdown did not complete\n${spawned.log}`,
		);
	}
}

export async function run(ctx: E2ETestContext): Promise<void> {
	// A signal during startup is parked and replayed once the server is
	// published. Before the loop-publish wakeup fix this took ~1 s (the uWS
	// sweep timer tick); it must now be handled on the first loop iteration.
	let signalSentAt = 0;
	assertGraceful(
		"SIGTERM during startup",
		await withSpawnedServer(ctx, "shutdown-during-startup", {
			readyMarker: READY_STARTUP,
			onReady: (pid) => {
				signalSentAt = Date.now();
				process.kill(pid, "SIGTERM");
			},
		}),
	);
	const startupLatencyMs = Date.now() - signalSentAt;
	if (startupLatencyMs > 500) {
		throw new Error(
			`SIGTERM during startup took ${startupLatencyMs}ms to exit; the loop wakeup was likely missed`,
		);
	}

	assertGraceful(
		"SIGINT on a running server",
		await withSpawnedServer(ctx, "shutdown-sigint", {
			readyMarker: READY_LISTENING,
			onReady: (pid) => process.kill(pid, "SIGINT"),
		}),
	);

	// A second termination signal skips the graceful path and exits by signal.
	// Different signal numbers are used because standard signals coalesce per
	// signal number: two back-to-back SIGTERMs can collapse into one delivery,
	// which would silently turn this into a plain graceful-shutdown test.
	const escalated = await withSpawnedServer(ctx, "shutdown-escalation", {
		readyMarker: READY_LISTENING,
		onReady: (pid) => {
			process.kill(pid, "SIGTERM");
			process.kill(pid, "SIGINT");
		},
	});
	if (
		escalated.exitCode !== null ||
		(escalated.signalCode !== "SIGTERM" && escalated.signalCode !== "SIGINT")
	) {
		throw new Error(
			`second signal did not escalate: exit=${escalated.exitCode} signal=${escalated.signalCode}\n${escalated.log}`,
		);
	}
}
