import * as fs from "node:fs";

import { type E2ETestContext, SERVER_BIN } from "./harness";

type Spawned = {
	exitCode: number | null;
	signalCode: string | null;
	log: string;
	/** When the server logged that it finished listening, or null. */
	listeningAt: number | null;
	/** When the process exit was observed. */
	exitedAt: number;
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
	const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
	let listeningAt: number | null = null;
	const drained = (async () => {
		for (;;) {
			const { value, done } = await reader.read();
			if (done) return;
			log += decoder.decode(value, { stream: true });
			const now = Date.now();
			if (log.includes(options.readyMarker)) markReady();
			if (listeningAt === null && log.includes(READY_LISTENING)) {
				listeningAt = now;
			}
		}
	})();

	// Bound the readiness wait too: a server that hangs before logging the
	// marker must not hang the suite. A child that dies early also satisfies
	// this wait so the exit assertions can report the real status.
	const readyOutcome = await withTimeout(
		Promise.race([ready, proc.exited]).then(() => "ready" as const),
		timeoutMs,
	);
	let timedOut = readyOutcome === "timeout";

	if (!timedOut && proc.exitCode === null && proc.signalCode === null) {
		try {
			options.onReady(proc.pid);
		} catch {
			// Child vanished between the check and the signal; the exit
			// assertions below report it.
		}
	}

	if (!timedOut) {
		const exitOutcome = await withTimeout(
			proc.exited.then(() => "exited" as const),
			timeoutMs,
		);
		timedOut = exitOutcome === "timeout";
	}

	if (timedOut) {
		proc.kill("SIGKILL");
	}
	await proc.exited;
	const exitedAt = Date.now();

	await drained;
	return {
		exitCode: proc.exitCode,
		signalCode: proc.signalCode,
		log,
		listeningAt,
		exitedAt,
	};
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
	const startup = await withSpawnedServer(ctx, "shutdown-during-startup", {
		readyMarker: READY_STARTUP,
		onReady: (pid) => process.kill(pid, "SIGTERM"),
	});
	assertGraceful("SIGTERM during startup", startup);

	// Measure from loop-ready, not from the signal: remaining init work is not
	// part of the wakeup path and would make this fail on a slow machine.
	if (startup.listeningAt === null) {
		throw new Error(`server never reported listening\n${startup.log}`);
	}
	const wakeupLatencyMs = startup.exitedAt - startup.listeningAt;
	if (wakeupLatencyMs > 500) {
		throw new Error(
			`SIGTERM during startup took ${wakeupLatencyMs}ms from listen to exit; the loop wakeup was likely missed`,
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
