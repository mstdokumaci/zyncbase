import { describe, expect, test } from "bun:test";
import { PendingRequests } from "./pending_requests.js";

describe("PendingRequests", () => {
	test("allocates monotonic ids", () => {
		const pending = new PendingRequests<string>();

		expect(pending.nextId()).toBe(1);
		expect(pending.nextId()).toBe(2);
		expect(pending.nextId()).toBe(3);
	});

	test("resolves and removes pending entries", async () => {
		const pending = new PendingRequests<string, { table: number }>();
		const promise = pending.register(1, { table: 2 });

		expect(pending.size).toBe(1);
		expect(pending.context(1)).toEqual({ table: 2 });
		expect(pending.resolve(1, "ok")).toBe(true);
		expect(pending.size).toBe(0);
		await expect(promise).resolves.toBe("ok");
	});

	test("rejects and removes pending entries", async () => {
		const pending = new PendingRequests<string>();
		const promise = pending.register(1, undefined);
		const err = new Error("failed");

		expect(pending.reject(1, err)).toBe(true);
		expect(pending.size).toBe(0);
		await expect(promise).rejects.toBe(err);
	});

	test("unknown ids return false", () => {
		const pending = new PendingRequests<string>();

		expect(pending.resolve(99, "ok")).toBe(false);
		expect(pending.reject(99, new Error("missing"))).toBe(false);
	});

	test("rejectAll clears before invoking rejections", async () => {
		const pending = new PendingRequests<string>();
		const err = new Error("disconnected");
		const p1 = pending.register(1, undefined);
		const p2 = pending.register(2, undefined);

		pending.rejectAll(err);

		expect(pending.size).toBe(0);
		await expect(p1).rejects.toBe(err);
		await expect(p2).rejects.toBe(err);
	});
});
