import { describe, expect, test } from "bun:test";
import { decode } from "@msgpack/msgpack";
import { ConnectionManager } from "./connection";
import {
	connectManager,
	encodeToBuffer,
	MockWebSocket,
	makeManager,
} from "./test-helpers";

describe("ConnectionManager", () => {
	describe("connect()", () => {
		test("sets binaryType to arraybuffer on WebSocket creation", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);
			expect(mockWs.binaryType).toBe("arraybuffer");
		});

		test("resolves when WebSocket opens", async () => {
			const { manager, mockWs } = makeManager();
			await expect(connectManager(manager, mockWs)).resolves.toBeUndefined();
		});

		test("emits 'connected' lifecycle event on open", async () => {
			const { manager, mockWs } = makeManager();
			const events: string[] = [];
			manager.on("connected", () => events.push("connected"));
			await connectManager(manager, mockWs);
			expect(events).toContain("connected");
		});

		test("emits 'statusChange' with 'connected' on open", async () => {
			const { manager, mockWs } = makeManager();
			const statuses: string[] = [];
			manager.on("statusChange", (s: unknown) => statuses.push(s as string));
			await connectManager(manager, mockWs);
			expect(statuses).toContain("connected");
		});

		test("rejects when WebSocket errors", async () => {
			const { manager, mockWs } = makeManager();
			const connectPromise = manager.connect();
			mockWs.triggerError();
			await expect(connectPromise).rejects.toMatchObject({
				code: "CONNECTION_FAILED",
			});
		});
	});

	describe("dispatch() — msg_id and pendingQueue", () => {
		test("assigns incrementing msg_ids starting at 1", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const p1 = manager.dispatch({
				type: "StoreSet",
				path: ["a", "b"],
				value: 1,
			});
			const p2 = manager.dispatch({
				type: "StoreSet",
				path: ["a", "c"],
				value: 2,
			});

			const msg1 = decode(mockWs.sentMessages[1]) as Record<string, unknown>;
			const msg2 = decode(mockWs.sentMessages[2]) as Record<string, unknown>;

			expect(msg1.id).toBe(2);
			expect(msg2.id).toBe(3);

			mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 2 }));
			mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 3 }));
			await p1;
			await p2;
		});

		test("resolves promise on type:ok response with matching id", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const p = manager.dispatch({
				type: "StoreSet",
				path: ["a", "b"],
				value: 1,
			});
			mockWs.triggerMessage(
				encodeToBuffer({ type: "ok", id: 2, value: [{ x: 1 }] }),
			);

			const result = await p;
			expect(result).toMatchObject({ type: "ok", id: 2 });
		});

		test("rejects promise on type:error response with matching id", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const p = manager.dispatch({
				type: "StoreSet",
				path: ["a", "b"],
				value: 1,
			});
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: 2,
					code: "PERMISSION_DENIED",
					message: "Not allowed",
				}),
			);

			await expect(p).rejects.toMatchObject({ code: "PERMISSION_DENIED" });
		});

		test("discards response with unknown id silently", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			expect(() =>
				mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 999 })),
			).not.toThrow();
		});
	});

	describe("StoreDelta routing", () => {
		test("routes StoreDelta to registered delta handler by subId", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const received: unknown[] = [];
			manager.onDelta((delta) => received.push(delta));

			const delta = {
				type: "StoreDelta",
				subId: 42,
				ops: [{ op: "set", path: ["users", "u1"], value: { name: "Alice" } }],
			};
			mockWs.triggerMessage(encodeToBuffer(delta));
			await (manager as unknown as { processingPromise: Promise<void> })
				.processingPromise;

			expect(received).toHaveLength(1);
			expect((received[0] as Record<string, unknown>).subId).toBe(42);
		});

		test("StoreDelta does not affect pendingQueue", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const p = manager.dispatch({
				type: "StoreSet",
				path: ["a", "b"],
				value: 1,
			});

			const delta = { type: "StoreDelta", subId: 99, ops: [] };
			mockWs.triggerMessage(encodeToBuffer(delta));

			mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 2 }));
			await expect(p).resolves.toMatchObject({ type: "ok", id: 2 });
		});
	});

	describe("SchemaSync race condition (ADR-025)", () => {
		test("processes StoreDelta only after SchemaSync is fully ready", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const received: unknown[] = [];
			manager.onDelta((delta) => received.push(delta));

			const schema = {
				type: "SchemaSync",
				tables: ["users"],
				fields: [["name", "age"]],
				fieldFlags: [[0b00, 0b00]],
			};
			mockWs.triggerMessage(encodeToBuffer(schema));

			const delta = {
				type: "StoreDelta",
				subId: 1,
				ops: [{ op: "set", path: [0, "u1", 0], value: "Alice" }],
			};
			mockWs.triggerMessage(encodeToBuffer(delta));

			await (manager as unknown as { processingPromise: Promise<void> })
				.processingPromise;

			expect(received).toHaveLength(1);
			expect(
				(received[0] as { ops: { path: string[] }[] }).ops[0].path,
			).toEqual(["users", "u1", "name"]);
		});
	});

	describe("lifecycle events", () => {
		test("emits 'disconnected' when WebSocket closes", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const events: string[] = [];
			manager.on("disconnected", () => events.push("disconnected"));
			mockWs.triggerClose();

			expect(events).toContain("disconnected");
		});

		test("emits 'error' on WebSocket error", async () => {
			const { manager, mockWs } = makeManager();
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

		test("rejects all pending requests when connection closes", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const p = manager.dispatch({
				type: "StoreSet",
				path: ["a", "b"],
				value: 1,
			});
			mockWs.triggerClose(1006, "Abnormal closure");

			await expect(p).rejects.toMatchObject({ code: "CONNECTION_FAILED" });
		});
	});

	describe("disconnect()", () => {
		test("closes the WebSocket and rejects pending requests", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const p = manager.dispatch({
				type: "StoreSet",
				path: ["a", "b"],
				value: 1,
			});
			manager.disconnect();

			await expect(p).rejects.toMatchObject({ code: "CONNECTION_FAILED" });
		});

		test("emits 'disconnected' event", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const events: string[] = [];
			manager.on("disconnected", () => events.push("disconnected"));
			manager.disconnect();

			expect(events).toContain("disconnected");
		});
	});

	describe("send()", () => {
		test("throws if WebSocket is not open", () => {
			const { manager } = makeManager();
			expect(() => manager.send(new Uint8Array([1, 2, 3]))).toThrow();
		});
	});

	describe("on() / off()", () => {
		test("off() removes a registered listener", async () => {
			const { manager, mockWs } = makeManager();
			const events: string[] = [];
			const handler = () => events.push("connected");
			manager.on("connected", handler);
			manager.off("connected", handler);

			await connectManager(manager, mockWs);

			expect(events).toHaveLength(0);
		});
	});

	describe("reconnection — exponential backoff", () => {
		test("emits 'reconnecting' on unexpected close when reconnect=true", async () => {
			const mockWs = new MockWebSocket();
			function wsFactory1() {
				return mockWs;
			}
			(globalThis as Record<string, unknown>).WebSocket = Object.assign(
				wsFactory1,
				{ OPEN: MockWebSocket.OPEN },
			);

			const manager = new ConnectionManager({
				url: "ws://localhost:3000",
				reconnect: true,
				reconnectDelay: 50,
				maxReconnectDelay: 5000,
			});

			const events: string[] = [];
			manager.on("reconnecting", () => events.push("reconnecting"));

			await connectManager(manager, mockWs);

			mockWs.triggerClose(1006, "Abnormal closure");

			await new Promise((r) => setTimeout(r, 10));
			expect(events).toContain("reconnecting");

			manager.disconnect();
		});

		test("does NOT reconnect when reconnect=false", async () => {
			const mockWs = new MockWebSocket();
			function wsFactory2() {
				return mockWs;
			}
			(globalThis as Record<string, unknown>).WebSocket = Object.assign(
				wsFactory2,
				{ OPEN: MockWebSocket.OPEN },
			);

			const manager = new ConnectionManager({
				url: "ws://localhost:3000",
				reconnect: false,
			});

			const events: string[] = [];
			manager.on("reconnecting", () => events.push("reconnecting"));
			manager.on("disconnected", () => events.push("disconnected"));

			await connectManager(manager, mockWs);

			mockWs.triggerClose(1006, "Abnormal closure");

			await new Promise((r) => setTimeout(r, 10));
			expect(events).not.toContain("reconnecting");
			expect(events).toContain("disconnected");
		});

		test("emits 'disconnected' and stops when maxReconnectAttempts exceeded", async () => {
			const mockWs = new MockWebSocket();
			function wsFactory3() {
				return mockWs;
			}
			(globalThis as Record<string, unknown>).WebSocket = Object.assign(
				wsFactory3,
				{ OPEN: MockWebSocket.OPEN },
			);

			const manager = new ConnectionManager({
				url: "ws://localhost:3000",
				reconnect: true,
				reconnectDelay: 10,
				maxReconnectDelay: 100,
				maxReconnectAttempts: 0,
			});

			const events: string[] = [];
			manager.on("reconnecting", () => events.push("reconnecting"));
			manager.on("disconnected", () => events.push("disconnected"));

			await connectManager(manager, mockWs);

			mockWs.triggerClose(1006, "Abnormal closure");

			await new Promise((r) => setTimeout(r, 10));
			expect(events).not.toContain("reconnecting");
			expect(events).toContain("disconnected");
		});

		test("cancels reconnect timer on disconnect()", async () => {
			const mockWs = new MockWebSocket();
			let wsInstances = 0;
			function wsFactory4() {
				wsInstances++;
				return mockWs;
			}
			(globalThis as Record<string, unknown>).WebSocket = Object.assign(
				wsFactory4,
				{ OPEN: MockWebSocket.OPEN },
			);

			const manager = new ConnectionManager({
				url: "ws://localhost:3000",
				reconnect: true,
				reconnectDelay: 200,
				maxReconnectDelay: 5000,
			});

			await connectManager(manager, mockWs);

			const instancesBeforeClose = wsInstances;
			mockWs.triggerClose(1006, "Abnormal closure");

			manager.disconnect();

			await new Promise((r) => setTimeout(r, 300));
			expect(wsInstances).toBe(instancesBeforeClose);
		});

		test("does NOT reconnect on intentional disconnect()", async () => {
			const mockWs = new MockWebSocket();
			function wsFactory5() {
				return mockWs;
			}
			(globalThis as Record<string, unknown>).WebSocket = Object.assign(
				wsFactory5,
				{ OPEN: MockWebSocket.OPEN },
			);

			const manager = new ConnectionManager({
				url: "ws://localhost:3000",
				reconnect: true,
				reconnectDelay: 50,
			});

			const events: string[] = [];
			manager.on("reconnecting", () => events.push("reconnecting"));

			await connectManager(manager, mockWs);

			manager.disconnect();

			await new Promise((r) => setTimeout(r, 100));
			expect(events).not.toContain("reconnecting");
		});
	});

	describe("_computeBackoffDelay()", () => {
		test("returns delay within ±10% jitter bounds and capped at maxReconnectDelay", () => {
			const manager = new ConnectionManager({
				url: "ws://localhost:3000",
				reconnectDelay: 1000,
				maxReconnectDelay: 30000,
			});

			for (let attempt = 0; attempt <= 5; attempt++) {
				const preCap = 1000 * 2 ** attempt;
				const delay = manager._computeBackoffDelay(attempt);
				const lower = preCap * 0.9;
				const upper = Math.min(preCap * 1.1, 30000);
				expect(delay).toBeGreaterThanOrEqual(lower);
				expect(delay).toBeLessThanOrEqual(upper);
			}
		});

		test("caps delay at maxReconnectDelay", () => {
			const manager = new ConnectionManager({
				url: "ws://localhost:3000",
				reconnectDelay: 1000,
				maxReconnectDelay: 5000,
			});

			const delay = manager._computeBackoffDelay(10);
			expect(delay).toBeLessThanOrEqual(5000);
		});

		test("uses default values when options not specified", () => {
			const manager = new ConnectionManager({ url: "ws://localhost:3000" });
			const delay = manager._computeBackoffDelay(0);
			expect(delay).toBeGreaterThanOrEqual(900);
			expect(delay).toBeLessThanOrEqual(1100);
		});
	});
});
