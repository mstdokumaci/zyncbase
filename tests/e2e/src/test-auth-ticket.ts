import { expect } from "bun:test";
import { ZyncBaseClient } from "./client";

const MAX_TICKET_BODY_BYTES = 4 * 1024;

function anonymousBody(): string {
	const hex = crypto.randomUUID().replaceAll("-", "");
	return JSON.stringify({ anonymousSubject: `anon:${hex}` });
}

export async function run(port: number): Promise<void> {
	const endpoint = `http://127.0.0.1:${port}/auth/ticket`;

	// An oversized body is answered once the whole body is read, and repeats
	// must not exhaust or corrupt per-request state.
	for (let i = 0; i < 3; i++) {
		const res = await fetch(endpoint, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: "x".repeat(64 * 1024),
		});
		expect(res.status).toBe(413);
		expect(await res.json()).toMatchObject({ code: "MESSAGE_TOO_LARGE" });
	}

	// A body exactly at the cap is parsed normally (and rejected as malformed).
	const atCap = await fetch(endpoint, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: " ".repeat(MAX_TICKET_BODY_BYTES),
	});
	expect(atCap.status).toBe(400);
	await atCap.body?.cancel();

	// Normal ticket issuance still works afterwards.
	const ok = await fetch(endpoint, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: anonymousBody(),
	});
	expect(ok.status).toBe(200);
	const ticket = (await ok.json()) as { ticket?: string };
	expect(typeof ticket.ticket).toBe("string");

	const client = new ZyncBaseClient(`ws://127.0.0.1:${port}`);
	try {
		await client.connect();
	} finally {
		client.close();
	}
}
