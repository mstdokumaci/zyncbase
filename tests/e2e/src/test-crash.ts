import * as fs from "node:fs";

import { ZyncBaseClient } from "./client";
import { type E2ETestContext, SERVER_BIN } from "./harness";

const READY_MARKER = "Server started successfully";
const READY_TIMEOUT_MS = 15_000;

type RunningServer = {
	process: Bun.Subprocess;
	log: () => string;
};

async function startServer(configPath: string): Promise<RunningServer> {
	const proc = Bun.spawn([SERVER_BIN, "--config", configPath], {
		cwd: process.cwd(),
		stdio: ["ignore", "ignore", "pipe"],
	});

	let log = "";
	let resolveReady = () => {};
	let rejectReady = (_err: Error) => {};
	const ready = new Promise<void>((resolve, reject) => {
		resolveReady = resolve;
		rejectReady = reject;
	});

	const timer = setTimeout(() => {
		rejectReady(new Error(`server did not become ready\n${log}`));
	}, READY_TIMEOUT_MS);

	const reader = proc.stderr.getReader();
	const decoder = new TextDecoder();
	void (async () => {
		for (;;) {
			const { value, done } = await reader.read();
			if (done) return;
			log += decoder.decode(value, { stream: true });
			if (log.includes(READY_MARKER)) {
				clearTimeout(timer);
				resolveReady();
			}
		}
	})();

	try {
		await ready;
	} catch (err) {
		proc.kill("SIGKILL");
		await proc.exited.catch(() => {});
		throw err;
	}

	return { process: proc, log: () => log };
}

export async function run(ctx: E2ETestContext): Promise<void> {
	const configPath = ctx.artifactPath("zyncbase-config-crash.json");
	fs.writeFileSync(
		configPath,
		JSON.stringify({
			server: { port: ctx.port },
			dataDir: ctx.dataPath("crash"),
			schema: ctx.schemaPath("schema-persistence.json"),
			storage: { synchronous: "full" },
			authentication: {
				anonymous: { enabled: true },
				ticket: { secret: "e2e-test-ticket-secret-32bytes!" },
			},
		}),
	);

	const recordCount = 25;

	const first = await startServer(configPath);
	const firstClient = new ZyncBaseClient(`ws://127.0.0.1:${ctx.port}`);
	try {
		await firstClient.connect();
		for (let i = 0; i < recordCount; i += 1) {
			await firstClient.store.set(
				["persistence", `crash-${i}`],
				{ status: `ok-${i}`, timestamp: i },
				{ confirm: "committed" },
			);
		}
	} finally {
		firstClient.close();
		try {
			process.kill(first.process.pid, "SIGKILL");
		} catch {
			// The server may already be gone; the exit status below reports it.
		}
		await first.process.exited.catch(() => {});
	}

	if (first.process.signalCode !== "SIGKILL") {
		throw new Error(
			`server did not die by SIGKILL: exit=${first.process.exitCode} signal=${first.process.signalCode}\n${first.log()}`,
		);
	}

	const second = await startServer(configPath);
	try {
		const secondClient = new ZyncBaseClient(`ws://127.0.0.1:${ctx.port}`);
		await secondClient.connect();
		try {
			for (let i = 0; i < recordCount; i += 1) {
				const doc = (await secondClient.get("public", [
					"persistence",
					`crash-${i}`,
				])) as { status?: string; timestamp?: number } | null | undefined;

				if (!doc || doc.timestamp !== i || doc.status !== `ok-${i}`) {
					throw new Error(
						`committed record ${i} was lost or corrupted after SIGKILL: ${JSON.stringify(doc)}`,
					);
				}
			}
		} finally {
			secondClient.close();
		}
	} finally {
		second.process.kill("SIGTERM");
		await second.process.exited.catch(() => {});
	}
}
