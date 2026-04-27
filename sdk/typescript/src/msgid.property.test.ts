import { describe, test } from "bun:test";
import { decode } from "@msgpack/msgpack";
import * as fc from "fast-check";
import { ConnectionManager } from "./connection";
import { AutoMockWebSocket } from "./test-helpers";
import type { ClientOptions } from "./types";

/**
 * Property 4: msg_id monotonicity and uniqueness
 * Validates: Requirements 3.3
 *
 * For any sequence of N dispatched requests (N ≥ 2), the assigned msg_id values
 * SHALL be strictly increasing integers with no duplicates.
 */

async function runMsgIdPropertyTest(n: number): Promise<boolean> {
	const originalWebSocket = (globalThis as unknown as { WebSocket: unknown })
		.WebSocket;
	(globalThis as unknown as { WebSocket: unknown }).WebSocket =
		AutoMockWebSocket;

	try {
		const options: ClientOptions = {
			url: "ws://localhost:9999",
			reconnect: false,
		};

		const manager = new ConnectionManager(options);
		await manager.connect();

		manager.schemaDictionary.processSchemaSync({
			tables: ["test", "users"],
			fields: [
				["id", "name"],
				["name", "age"],
			],
			fieldFlags: [
				[0b11, 0b00],
				[0b00, 0b00],
			],
		});

		const dispatchPromises: Promise<unknown>[] = [];
		for (let i = 0; i < n; i++) {
			dispatchPromises.push(
				manager
					.dispatch({ type: "StoreQuery", table_index: "test" })
					.catch(() => {}),
			);
		}

		await Promise.resolve();

		const mockWs = (manager as unknown as { ws: AutoMockWebSocket })
			.ws as AutoMockWebSocket;
		const sentMessages = mockWs.sentMessages;

		const ids: number[] = sentMessages.map((bytes) => {
			const decoded = decode(bytes) as Record<string, unknown>;
			return decoded.id as number;
		});

		manager.disconnect();

		if (ids.length !== n + 1) return false;

		if (ids[0] !== 1) return false;

		for (let i = 1; i < ids.length; i++) {
			if (ids[i] !== i + 1) return false;
		}

		const unique = new Set(ids);
		if (unique.size !== ids.length) return false;

		return true;
	} finally {
		(globalThis as unknown as { WebSocket: unknown }).WebSocket =
			originalWebSocket;
	}
}

describe("ConnectionManager", () => {
	test("Property 4: msg_id values are strictly increasing integers with no duplicates", async () => {
		await fc.assert(
			fc.asyncProperty(fc.integer({ min: 2, max: 100 }), runMsgIdPropertyTest),
			{ numRuns: 100 },
		);
	});
});
