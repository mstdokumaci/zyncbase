/**
 * Preservation property tests for encodeQueryOptions and WebSocket mock injection.
 *
 * These tests MUST PASS on the UNFIXED code to establish a baseline.
 * They will continue to pass after the refactor, proving behavioral preservation.
 *
 * Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9
 */

import { describe, expect, test } from "bun:test";
import { ConnectionManager } from "./connection";
import { encodeQueryOptions } from "./store";
import { connectManager, installMockWs, MockWebSocket } from "./test-helpers";
import type { ClientOptions, JsonValue } from "./types";

// ─── Property 2: encodeQueryOptions Output Stability ─────────────────────────
//
// For any valid QueryOptions input, encodeQueryOptions SHALL produce
// wire-format output that is deeply equal to the expected baseline.
//
// Validates: Requirements 2.7, 3.4

describe("encodeQueryOptions — preservation property", () => {
	test("empty options returns empty object", () => {
		const result = encodeQueryOptions({});
		expect(result).toEqual({});
	});

	test("limit only", () => {
		const result = encodeQueryOptions({ limit: 10 });
		expect(result).toEqual({ limit: 10 });
	});

	test("after cursor only", () => {
		const result = encodeQueryOptions({ after: "cursor_abc" });
		expect(result).toEqual({ after: "cursor_abc" });
	});

	test("limit and after together", () => {
		const result = encodeQueryOptions({ limit: 5, after: "tok_xyz" });
		expect(result).toEqual({ limit: 5, after: "tok_xyz" });
	});

	test("orderBy asc", () => {
		const result = encodeQueryOptions({ orderBy: { name: "asc" } });
		expect(result).toEqual({ orderBy: ["name", 0] });
	});

	test("orderBy desc", () => {
		const result = encodeQueryOptions({ orderBy: { created_at: "desc" } });
		expect(result).toEqual({ orderBy: ["created_at", 1] });
	});

	test("where with direct equality", () => {
		const result = encodeQueryOptions({ where: { status: "active" } });
		expect(result).toEqual({
			conditions: [["status", 0, "active"]],
		});
	});

	test("where with null equality", () => {
		const result = encodeQueryOptions({ where: { deleted_at: null } });
		expect(result).toEqual({
			conditions: [["deleted_at", 0, null]],
		});
	});

	test("where with gte operator", () => {
		const result = encodeQueryOptions({ where: { age: { gte: 18 } } });
		expect(result).toEqual({
			conditions: [["age", 4, 18]],
		});
	});

	test("where with lte operator", () => {
		const result = encodeQueryOptions({ where: { score: { lte: 100 } } });
		expect(result).toEqual({
			conditions: [["score", 5, 100]],
		});
	});

	test("where with gt operator", () => {
		const result = encodeQueryOptions({ where: { count: { gt: 0 } } });
		expect(result).toEqual({
			conditions: [["count", 2, 0]],
		});
	});

	test("where with lt operator", () => {
		const result = encodeQueryOptions({ where: { price: { lt: 50 } } });
		expect(result).toEqual({
			conditions: [["price", 3, 50]],
		});
	});

	test("where with eq operator", () => {
		const result = encodeQueryOptions({ where: { id: { eq: "abc" } } });
		expect(result).toEqual({
			conditions: [["id", 0, "abc"]],
		});
	});

	test("where with ne operator", () => {
		const result = encodeQueryOptions({ where: { status: { ne: "deleted" } } });
		expect(result).toEqual({
			conditions: [["status", 1, "deleted"]],
		});
	});

	test("where with contains operator", () => {
		const result = encodeQueryOptions({
			where: { name: { contains: "Alice" } },
		});
		expect(result).toEqual({
			conditions: [["name", 6, "Alice"]],
		});
	});

	test("where with startsWith operator", () => {
		const result = encodeQueryOptions({
			where: { email: { startsWith: "admin" } },
		});
		expect(result).toEqual({
			conditions: [["email", 7, "admin"]],
		});
	});

	test("where with endsWith operator", () => {
		const result = encodeQueryOptions({
			where: { email: { endsWith: ".com" } },
		});
		expect(result).toEqual({
			conditions: [["email", 8, ".com"]],
		});
	});

	test("where with in operator", () => {
		const result = encodeQueryOptions({
			where: { role: { in: ["admin", "mod"] } },
		});
		expect(result).toEqual({
			conditions: [["role", 9, ["admin", "mod"]]],
		});
	});

	test("where with notIn operator", () => {
		const result = encodeQueryOptions({
			where: { status: { notIn: ["banned", "deleted"] } },
		});
		expect(result).toEqual({
			conditions: [["status", 10, ["banned", "deleted"]]],
		});
	});

	test("where with isNull operator", () => {
		const result = encodeQueryOptions({
			where: { deleted_at: { isNull: true } },
		});
		expect(result).toEqual({
			conditions: [["deleted_at", 11]],
		});
	});

	test("where with isNotNull operator", () => {
		const result = encodeQueryOptions({
			where: { email: { isNotNull: true } },
		});
		expect(result).toEqual({
			conditions: [["email", 12]],
		});
	});

	test("where with multiple fields", () => {
		const result = encodeQueryOptions({
			where: { status: "active", age: { gte: 18 } },
		});
		expect(result.conditions).toHaveLength(2);
		expect(result.conditions).toContainEqual(["status", 0, "active"]);
		expect(result.conditions).toContainEqual(["age", 4, 18]);
	});

	test("where with or clause", () => {
		const result = encodeQueryOptions({
			where: {
				or: [{ status: "active" }, { role: "admin" }],
			},
		});
		expect(result).toEqual({
			orConditions: [
				["status", 0, "active"],
				["role", 0, "admin"],
			],
		});
	});

	test("where with both conditions and or clause", () => {
		const result = encodeQueryOptions({
			where: {
				age: { gte: 18 },
				or: [{ status: "active" }, { role: "admin" }],
			},
		});
		expect(result.conditions).toEqual([["age", 4, 18]]);
		expect(result.orConditions).toEqual([
			["status", 0, "active"],
			["role", 0, "admin"],
		]);
	});

	test("full options: where + orderBy + limit + after", () => {
		const result = encodeQueryOptions({
			where: { status: "active" },
			orderBy: { created_at: "desc" },
			limit: 20,
			after: "cursor_123",
		});
		expect(result).toEqual({
			conditions: [["status", 0, "active"]],
			orderBy: ["created_at", 1],
			limit: 20,
			after: "cursor_123",
		});
	});

	test("where with nested field object (flattened with __)", () => {
		const result = encodeQueryOptions({
			where: { address: { city: "NYC" } },
		});
		expect(result).toEqual({
			conditions: [["address__city", 0, "NYC"]],
		});
	});

	test("where with deeply nested field", () => {
		const result = encodeQueryOptions({
			where: { profile: { settings: { theme: "dark" } } },
		});
		expect(result).toEqual({
			conditions: [["profile__settings__theme", 0, "dark"]],
		});
	});

	test("property: limit values 0..100 all encode correctly", () => {
		for (let limit = 0; limit <= 100; limit++) {
			const result = encodeQueryOptions({ limit });
			expect(result.limit).toBe(limit);
		}
	});

	test("property: orderBy asc/desc encodes to 0/1 for any field name", () => {
		const fields = ["id", "name", "created_at", "updated_at", "score", "age"];
		for (const field of fields) {
			const asc = encodeQueryOptions({ orderBy: { [field]: "asc" } });
			expect(asc.orderBy).toEqual([field, 0]);

			const desc = encodeQueryOptions({ orderBy: { [field]: "desc" } });
			expect(desc.orderBy).toEqual([field, 1]);
		}
	});

	test("property: all operator codes map correctly", () => {
		const opCases: Array<[string, JsonValue, number]> = [
			["eq", "val", 0],
			["ne", "val", 1],
			["gt", 5, 2],
			["lt", 5, 3],
			["gte", 5, 4],
			["lte", 5, 5],
			["contains", "x", 6],
			["startsWith", "x", 7],
			["endsWith", "x", 8],
			["in", ["a", "b"], 9],
			["notIn", ["a", "b"], 10],
		];
		for (const [op, val, expectedCode] of opCases) {
			const result = encodeQueryOptions({ where: { field: { [op]: val } } });
			expect(result.conditions).toBeDefined();
			expect(result.conditions?.[0][1]).toBe(expectedCode);
		}
	});

	test("property: isNull/isNotNull produce 2-tuple (no value)", () => {
		const isNull = encodeQueryOptions({ where: { f: { isNull: true } } });
		expect(isNull.conditions?.[0]).toHaveLength(2);
		expect(isNull.conditions?.[0][1]).toBe(11);

		const isNotNull = encodeQueryOptions({ where: { f: { isNotNull: true } } });
		expect(isNotNull.conditions?.[0]).toHaveLength(2);
		expect(isNotNull.conditions?.[0][1]).toBe(12);
	});

	test("property: empty where object produces no conditions", () => {
		const result = encodeQueryOptions({ where: {} });
		expect(result.conditions).toBeUndefined();
		expect(result.orConditions).toBeUndefined();
	});

	test("property: or with empty array produces no orConditions", () => {
		const result = encodeQueryOptions({ where: { or: [] } });
		expect(result.orConditions).toBeUndefined();
	});
});

// ─── Property 1: WebSocket Mock Injection Preserved ──────────────────────────
//
// For any MockWebSocket instance assigned via the factory function pattern,
// the ConnectionManager SHALL receive that exact instance.
//
// Validates: Requirements 2.4, 2.5, 2.6, 3.1

const defaultOptions: ClientOptions = {
	url: "ws://localhost:3000",
	reconnect: false,
};

describe("WebSocket mock injection — preservation property", () => {
	test("factory function pattern injects the correct mockWs instance", async () => {
		const mockWs = new MockWebSocket();
		installMockWs(mockWs);

		const manager = new ConnectionManager(defaultOptions);
		await connectManager(manager, mockWs);

		expect(mockWs.binaryType).toBe("arraybuffer");
	});

	test("factory function pattern: send() reaches the injected mockWs", async () => {
		const mockWs = new MockWebSocket();
		installMockWs(mockWs);

		const manager = new ConnectionManager(defaultOptions);
		await connectManager(manager, mockWs);

		manager.send(new Uint8Array([1, 2, 3]));
		expect(mockWs.sentMessages).toHaveLength(2);
	});

	test("factory function pattern: wsInstances counter increments correctly", async () => {
		const mockWs = new MockWebSocket();
		let wsInstances = 0;

		function wsFactory() {
			wsInstances++;
			return mockWs;
		}
		(globalThis as Record<string, unknown>).WebSocket = Object.assign(
			wsFactory,
			{ OPEN: MockWebSocket.OPEN },
		);

		const manager = new ConnectionManager(defaultOptions);
		await connectManager(manager, mockWs);

		expect(wsInstances).toBe(1);
	});

	test("factory function pattern: error event propagates correctly", async () => {
		const mockWs = new MockWebSocket();
		installMockWs(mockWs);

		const manager = new ConnectionManager(defaultOptions);
		const errors: unknown[] = [];
		manager.on("error", (e: unknown) => errors.push(e));

		const connectPromise = manager.connect();
		mockWs.triggerError();

		try {
			await connectPromise;
		} catch {}

		expect(errors).toHaveLength(1);
		expect((errors[0] as Record<string, unknown>).code).toBe(
			"CONNECTION_FAILED",
		);
	});

	test("factory function pattern: close event propagates correctly", async () => {
		const mockWs = new MockWebSocket();
		installMockWs(mockWs);

		const manager = new ConnectionManager(defaultOptions);
		await connectManager(manager, mockWs);

		const events: string[] = [];
		manager.on("disconnected", () => events.push("disconnected"));
		mockWs.triggerClose();

		expect(events).toContain("disconnected");
	});

	test("factory function pattern: multiple independent mock instances work correctly", async () => {
		for (let i = 0; i < 3; i++) {
			const mockWs = new MockWebSocket();
			installMockWs(mockWs);

			const manager = new ConnectionManager(defaultOptions);
			await connectManager(manager, mockWs);

			expect(mockWs.binaryType).toBe("arraybuffer");
		}
	});
});
