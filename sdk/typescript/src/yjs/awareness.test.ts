import { describe, expect, test } from "bun:test";

import * as Y from "yjs";

import type { Presence } from "../types.js";
import {
	type AwarenessPresence,
	PresenceAwarenessBridge,
} from "./awareness.js";
import { FakePresence } from "./test-helpers.js";

const NAMESPACE = "doc-1";

interface Harness {
	bridge: PresenceAwarenessBridge;
	presence: FakePresence;
	client: AwarenessPresence;
	errors: unknown[];
}

function makeHarness(
	doc: Y.Doc,
	options: { namespace?: string } = {},
): Harness {
	const presence = new FakePresence();
	const client: AwarenessPresence = {
		presence: presence as unknown as Presence,
		presenceNamespace: NAMESPACE,
	};
	const errors: unknown[] = [];
	const bridge = new PresenceAwarenessBridge({
		doc,
		client,
		namespace: options.namespace ?? NAMESPACE,
		onError: (error) => errors.push(error),
	});
	return { bridge, presence, client, errors };
}

function lastSet(presence: FakePresence): Record<string, unknown> {
	const call = presence.setCalls.at(-1);
	if (call === undefined) throw new Error("no presence.set call");
	return call;
}

function flush(): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, 0));
}

describe("PresenceAwarenessBridge local state", () => {
	test("publishes the local state with the client id and clears removed keys", () => {
		const doc = new Y.Doc();
		const { bridge, presence } = makeHarness(doc);
		bridge.start();

		expect(presence.setCalls[0]).toEqual({ yjsClientId: doc.clientID });

		bridge.awareness.setLocalStateField("cursor", { x: 1, y: 2 });
		expect(lastSet(presence)).toEqual({
			cursor: { x: 1, y: 2 },
			yjsClientId: doc.clientID,
		});

		bridge.awareness.setLocalState({});
		expect(lastSet(presence)).toEqual({
			cursor: { x: null, y: null },
			yjsClientId: doc.clientID,
		});

		bridge.destroy();
		doc.destroy();
	});

	test("clearing an object field expands it into leaf nulls", () => {
		const doc = new Y.Doc();
		const { bridge, presence } = makeHarness(doc);
		bridge.start();
		bridge.awareness.setLocalState({ cursor: { x: 1, y: 2 } });

		bridge.awareness.setLocalState({ cursor: null });
		expect(lastSet(presence)).toEqual({
			cursor: { x: null, y: null },
			yjsClientId: doc.clientID,
		});

		bridge.awareness.setLocalState({ cursor: { x: null, y: 2 } });
		expect(lastSet(presence)).toEqual({
			cursor: { x: null, y: 2 },
			yjsClientId: doc.clientID,
		});

		bridge.destroy();
		doc.destroy();
	});

	test("clears nested leaves omitted from a changed object", () => {
		const doc = new Y.Doc();
		const { bridge, presence } = makeHarness(doc);
		bridge.start();
		bridge.awareness.setLocalState({ cursor: { x: 1, y: 2 } });

		bridge.awareness.setLocalState({ cursor: { x: 3 } });
		expect(lastSet(presence)).toEqual({
			cursor: { x: 3, y: null },
			yjsClientId: doc.clientID,
		});

		bridge.destroy();
		doc.destroy();
	});

	test("retries a tombstone after the publish fails", async () => {
		const doc = new Y.Doc();
		const { bridge, presence } = makeHarness(doc);
		bridge.start();
		bridge.awareness.setLocalState({ cursor: { x: 1, y: 2 } });

		presence.failures = 1;
		bridge.awareness.setLocalState({});
		await flush();

		bridge.awareness.setLocalState({ status: "active" });
		expect(lastSet(presence)).toEqual({
			cursor: { x: null, y: null },
			status: "active",
			yjsClientId: doc.clientID,
		});

		bridge.destroy();
		doc.destroy();
	});

	test("clearing the local state removes the client id so peers drop the entry", () => {
		const doc = new Y.Doc();
		const { bridge, presence } = makeHarness(doc);
		bridge.start();
		bridge.awareness.setLocalState({ cursor: { x: 1, y: 2 } });

		bridge.awareness.setLocalState(null);
		expect(lastSet(presence)).toEqual({
			cursor: { x: null, y: null },
			yjsClientId: null,
		});

		bridge.destroy();
		doc.destroy();
	});

	test("stop clears every field this bridge published", async () => {
		const doc = new Y.Doc();
		const { bridge, presence } = makeHarness(doc);
		bridge.start();
		bridge.awareness.setLocalState({ cursor: { x: 1, y: 2 } });
		await flush();

		bridge.stop();
		expect(lastSet(presence)).toEqual({
			cursor: { x: null, y: null },
			yjsClientId: null,
		});
		expect(presence.subscribers).toBe(0);
		doc.destroy();
	});
});

describe("PresenceAwarenessBridge remote state", () => {
	test("applies presence entries as awareness states and removes leavers", () => {
		const doc = new Y.Doc();
		const { bridge, presence } = makeHarness(doc);
		bridge.start();

		presence.emit([
			{
				userId: "u2",
				data: { yjsClientId: 4242, cursor: { x: 5, y: 6 } },
				joinedAt: 1,
			},
		]);
		expect(bridge.awareness.getStates().get(4242)).toEqual({
			cursor: { x: 5, y: 6 },
		});

		presence.emit([]);
		expect(bridge.awareness.getStates().has(4242)).toBe(false);

		bridge.destroy();
		doc.destroy();
	});

	test("restores a remote state removed by the awareness timeout", () => {
		const doc = new Y.Doc();
		const { bridge, presence } = makeHarness(doc);
		bridge.start();
		const entry = {
			userId: "u2",
			data: { yjsClientId: 99, cursor: { x: 1 } },
			joinedAt: 1,
		};
		presence.emit([entry]);
		expect(bridge.awareness.getStates().has(99)).toBe(true);

		// The awareness timeout deletes the state but keeps its meta clock.
		bridge.awareness.states.delete(99);
		presence.emit([entry]);
		expect(bridge.awareness.getStates().get(99)).toEqual({
			cursor: { x: 1 },
		});

		bridge.destroy();
		doc.destroy();
	});

	test("ignores entries without a client id, its own id, and duplicates", () => {
		const doc = new Y.Doc();
		const { bridge, presence } = makeHarness(doc);
		bridge.start();

		presence.emit([
			{ userId: "u1", data: { cursor: { x: 1 } }, joinedAt: 1 },
			{
				userId: "self",
				data: { yjsClientId: doc.clientID, cursor: { x: 2 } },
				joinedAt: 1,
			},
			{
				userId: "u2",
				data: { yjsClientId: 77, cursor: { x: 3 } },
				joinedAt: 1,
			},
			{
				userId: "u3",
				data: { yjsClientId: 77, cursor: { x: 4 } },
				joinedAt: 1,
			},
		]);

		expect(bridge.awareness.getLocalState()).toEqual({});
		expect(bridge.awareness.getStates().get(77)).toEqual({
			cursor: { x: 3 },
		});

		bridge.destroy();
		doc.destroy();
	});

	test("an unchanged snapshot refreshes the timeout without a new clock", () => {
		const doc = new Y.Doc();
		const { bridge, presence } = makeHarness(doc);
		bridge.start();

		const entry = {
			userId: "u2",
			data: { yjsClientId: 99, cursor: { x: 1 } },
			joinedAt: 1,
		};
		presence.emit([entry]);
		const meta = bridge.awareness.meta.get(99);
		expect(meta).toBeDefined();
		if (meta === undefined) throw new Error("missing meta");
		const clock = meta.clock;
		meta.lastUpdated = 0;

		presence.emit([entry]);
		expect(meta.clock).toBe(clock);
		expect(meta.lastUpdated).toBeGreaterThan(0);

		bridge.destroy();
		doc.destroy();
	});

	test("stop removes applied remote states", async () => {
		const doc = new Y.Doc();
		const { bridge, presence } = makeHarness(doc);
		bridge.start();
		presence.emit([
			{
				userId: "u2",
				data: { yjsClientId: 12, cursor: { x: 1 } },
				joinedAt: 1,
			},
		]);
		expect(bridge.awareness.getStates().has(12)).toBe(true);

		bridge.stop();
		expect(bridge.awareness.getStates().has(12)).toBe(false);
		await flush();
		doc.destroy();
	});
});

describe("PresenceAwarenessBridge guards", () => {
	test("rejects a namespace that does not match the client", () => {
		const doc = new Y.Doc();
		expect(() => makeHarness(doc, { namespace: "other" })).toThrow(
			/does not match/,
		);
		doc.destroy();
	});

	test("allows one active bridge per client", async () => {
		const presence = new FakePresence();
		const client: AwarenessPresence = {
			presence: presence as unknown as Presence,
			presenceNamespace: NAMESPACE,
		};
		const errors: unknown[] = [];
		const firstDoc = new Y.Doc();
		const secondDoc = new Y.Doc();
		const first = new PresenceAwarenessBridge({
			doc: firstDoc,
			client,
			namespace: NAMESPACE,
			onError: (error) => errors.push(error),
		});
		const second = new PresenceAwarenessBridge({
			doc: secondDoc,
			client,
			namespace: NAMESPACE,
			onError: (error) => errors.push(error),
		});

		first.start();
		second.start();
		expect(errors).toHaveLength(1);
		expect(presence.subscribers).toBe(1);

		first.stop();
		await flush();
		expect(presence.subscribers).toBe(0);
		second.start();
		expect(presence.subscribers).toBe(1);

		second.destroy();
		firstDoc.destroy();
		secondDoc.destroy();
	});
});
