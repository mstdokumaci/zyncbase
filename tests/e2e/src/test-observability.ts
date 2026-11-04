import { expect } from "bun:test";
import { ZyncBaseClient } from "./client";

type Stats = {
	uptime_seconds: number;
	connections: { active: number; total: number };
	messages: { received_total: number; sent_total: number };
	errors: { sent_total: number; rate_limit_rejections_total: number };
	storage: {
		last_checkpoint_time: number;
		wal_size_bytes: number;
		checkpoint_count: number;
		failed_checkpoint_count: number;
		last_checkpoint_duration_ms: number;
	};
};

async function readStats(port: number): Promise<Stats> {
	const res = await fetch(`http://127.0.0.1:${port}/stats`);
	expect(res.status).toBe(200);
	return (await res.json()) as Stats;
}

export async function run(port: number): Promise<void> {
	// 1. Test /health endpoint
	const healthRes = await fetch(`http://127.0.0.1:${port}/health`);
	expect(healthRes.status).toBe(200);
	expect(healthRes.headers.get("content-type")).toContain("application/json");
	const healthJson = await healthRes.json();
	expect(healthJson).toEqual({ status: "ok" });

	// 2. Test /stats endpoint before connecting clients
	const statsRes1 = await fetch(`http://127.0.0.1:${port}/stats`);
	expect(statsRes1.status).toBe(200);
	expect(statsRes1.headers.get("content-type")).toContain("application/json");
	expect(statsRes1.headers.get("cache-control")).toBe("no-store");
	const stats1 = (await statsRes1.json()) as Stats;

	expect(typeof stats1.uptime_seconds).toBe("number");
	expect(stats1.uptime_seconds).toBeGreaterThanOrEqual(0);
	expect(typeof stats1.connections.active).toBe("number");
	expect(typeof stats1.connections.total).toBe("number");
	expect(typeof stats1.messages.received_total).toBe("number");
	expect(typeof stats1.messages.sent_total).toBe("number");
	expect(typeof stats1.errors.sent_total).toBe("number");
	expect(typeof stats1.errors.rate_limit_rejections_total).toBe("number");
	expect(typeof stats1.storage.last_checkpoint_time).toBe("number");
	expect(typeof stats1.storage.wal_size_bytes).toBe("number");
	expect(typeof stats1.storage.checkpoint_count).toBe("number");
	expect(typeof stats1.storage.failed_checkpoint_count).toBe("number");
	expect(typeof stats1.storage.last_checkpoint_duration_ms).toBe("number");

	const initialTotal = stats1.connections.total;
	const initialSent = stats1.messages.sent_total;

	// 3. Connect a client and verify stats reflect activity
	const client = new ZyncBaseClient(`ws://127.0.0.1:${port}`);
	await client.connect();

	// Wait briefly for server state to update
	await new Promise((r) => setTimeout(r, 100));

	const stats2 = await readStats(port);

	expect(stats2.connections.total).toBeGreaterThanOrEqual(initialTotal + 1);
	expect(stats2.connections.active).toBeGreaterThanOrEqual(1);
	expect(stats2.messages.sent_total).toBeGreaterThan(initialSent);

	await client.close();

	// Poll until the close callback is processed instead of assuming a delay.
	const deadline = Date.now() + 2_000;
	let stats3 = await readStats(port);
	while (stats3.connections.active !== 0 && Date.now() < deadline) {
		await new Promise((r) => setTimeout(r, 25));
		stats3 = await readStats(port);
	}
	expect(stats3.connections.active).toBe(0);
}
