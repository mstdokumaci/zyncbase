import { describe, expect, test } from "bun:test";
import type { ConnectionManager } from "./connection.js";
import { StoreImpl } from "./store.js";
import { SubscriptionTracker } from "./subscriptions.js";
import type { JsonValue, OkResponse } from "./types.js";

type DispatchMessage = Parameters<ConnectionManager["dispatch"]>[0];

function makeStore(responses: Array<OkResponse | Error> = []) {
	const messages: DispatchMessage[] = [];
	const errors: unknown[] = [];
	const pendingResponses = [...responses];
	const conn = {
		dispatch: async (msg: DispatchMessage): Promise<OkResponse> => {
			messages.push(msg);
			const response = pendingResponses.shift();
			if (response instanceof Error) throw response;
			return response ?? { type: "ok", id: messages.length };
		},
	} as ConnectionManager;
	const tracker = new SubscriptionTracker();
	const store = new StoreImpl(conn, tracker, (err) => errors.push(err));

	return { store, tracker, messages, errors };
}

async function flushPromises(): Promise<void> {
	await Promise.resolve();
	await Promise.resolve();
}

describe("StoreImpl", () => {
	test("set dispatches one built StoreSet message", async () => {
		const { store, messages } = makeStore();

		await store.set("users.u1", {
			name: "Ada",
			address: { city: "London" },
		});

		expect(messages).toEqual([
			{
				type: "StoreSet",
				path: ["users", "u1"],
				value: {
					name: "Ada",
					address__city: "London",
				},
			},
		]);
	});

	test("get dispatches StoreQuery and returns shaped document results", async () => {
		const { store, messages } = makeStore([
			{
				type: "ok",
				id: 1,
				value: [{ name: "Ada", address__city: "London" }],
			},
		]);

		await expect(store.get("users.u1")).resolves.toEqual({
			name: "Ada",
			address: { city: "London" },
		});
		expect(messages).toEqual([
			{
				type: "StoreQuery",
				table_index: "users",
				conditions: [["id", 0, "u1"]],
			},
		]);
	});

	test("dispatch errors are emitted and rethrown as SDK errors", async () => {
		const { store, errors } = makeStore([new Error("socket failed")]);

		await expect(store.set("users.u1", { name: "Ada" })).rejects.toMatchObject({
			code: "INTERNAL_ERROR",
			message: "socket failed",
		});
		expect(errors).toHaveLength(1);
		expect(errors[0]).toMatchObject({
			code: "INTERNAL_ERROR",
			message: "socket failed",
		});
	});

	test("listen registers with SubscriptionTracker and emits initial snapshot", async () => {
		const { store, messages } = makeStore([
			{
				type: "ok",
				id: 1,
				subId: 7,
				value: [{ id: "u1", name: "Ada" }],
			},
		]);
		const values: JsonValue[] = [];

		const unlisten = store.listen("users.u1", (value) => values.push(value));
		await flushPromises();

		expect(messages[0]).toEqual({
			type: "StoreSubscribe",
			table_index: "users",
			conditions: [["id", 0, "u1"]],
		});
		expect(values).toEqual([{ id: "u1", name: "Ada" }]);

		unlisten();
		expect(messages[1]).toEqual({ type: "StoreUnsubscribe", subId: 7 });
	});

	test("subscribe registers collection view and loadMore dispatches cursor request", async () => {
		const { store, messages } = makeStore([
			{
				type: "ok",
				id: 1,
				subId: 9,
				value: [{ id: "u1", name: "Ada" }],
				hasMore: true,
				nextCursor: "next",
			},
			{
				type: "ok",
				id: 2,
				value: [{ id: "u2", name: "Grace" }],
				hasMore: false,
				nextCursor: null,
			},
		]);
		const snapshots: JsonValue[][] = [];

		const handle = store.subscribe("users", {}, (value) =>
			snapshots.push(value),
		);
		await flushPromises();

		expect(handle.hasMore).toBe(true);
		expect(snapshots).toEqual([[{ id: "u1", name: "Ada" }]]);

		await handle.loadMore();

		expect(messages[1]).toEqual({
			type: "StoreLoadMore",
			subId: 9,
			nextCursor: "next",
			table_index: "users",
		});
		expect(handle.hasMore).toBe(false);
		expect(snapshots.at(-1)).toEqual([
			{ id: "u1", name: "Ada" },
			{ id: "u2", name: "Grace" },
		]);
	});
});
