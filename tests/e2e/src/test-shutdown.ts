import * as fs from "node:fs";

import { type E2ETestContext, SERVER_BIN } from "./harness";

type Spawned = {
	exitCode: number | null;
	signalCode: string | null;
	log: string;
};

// Logged after installSignalHandlers() runs, so it marks the earliest point
// where a SIGTERM must be handled instead of using the default action.
const SIGNALS_INSTALLED_MARKER = "Initializing ZyncBase server";

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

/**
 * Spawn the server, wait until it has installed signal handlers, then let
 * `onReady` signal it. Returns the exit status and the captured output.
 */
async function withSpawnedServer(
	ctx: E2ETestContext,
	name: string,
	onReady: (pid: number) => void,
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
	void (async () => {
		for (;;) {
			const { value, done } = await reader.read();
			if (done) return;
			log += decoder.decode(value, { stream: true });
			if (log.includes(SIGNALS_INSTALLED_MARKER)) markReady();
		}
	})();

	// If the process dies before logging, proceed anyway so the assertion below
	// reports the real exit status instead of hanging.
	await Promise.race([ready, proc.exited]);
	onReady(proc.pid);
	await proc.exited;
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
	// Before the fix this died from the default SIGTERM action: no checkpoint,
	// exit status 143.
	assertGraceful(
		"SIGTERM during startup",
		await withSpawnedServer(ctx, "shutdown-during-startup", (pid) => {
			process.kill(pid, "SIGTERM");
		}),
	);

	assertGraceful(
		"SIGINT on a running server",
		await withSpawnedServer(ctx, "shutdown-sigint", (pid) => {
			process.kill(pid, "SIGINT");
		}),
	);

	// A second signal skips the graceful path and exits by signal. Both are sent
	// back to back so the second lands while the shutdown is still running.
	const escalated = await withSpawnedServer(
		ctx,
		"shutdown-escalation",
		(pid) => {
			process.kill(pid, "SIGTERM");
			process.kill(pid, "SIGTERM");
		},
	);
	if (escalated.signalCode !== "SIGTERM" || escalated.exitCode !== null) {
		throw new Error(
			`second SIGTERM did not escalate: exit=${escalated.exitCode} signal=${escalated.signalCode}\n${escalated.log}`,
		);
	}
}
