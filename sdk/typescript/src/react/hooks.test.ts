import { GlobalRegistrator } from "@happy-dom/global-registrator";

GlobalRegistrator.register();

import { afterEach, describe, expect, test } from "bun:test";
import type { ReactNode } from "react";
import { createElement, StrictMode } from "react";
import type { ZyncBaseClient } from "../client.js";
import {
	createZyncBaseReact,
	useAction,
	useClient,
	useListen,
	usePresence,
	useQuery,
	useSyncStatus,
	ZyncBaseProvider,
} from "./index.js";

// Dynamic imports run after happy-dom globals exist.
const { act, cleanup, render, renderHook, waitFor } = await import(
	"@testing-library/react"
);

afterEach(() => {
	cleanup();
});

// ─── Mocks ──────────────────────────────────────────────────────────────────

class FakeSubscription {
	unsubscribed = 0;
	snapshot: unknown[] = [];
	loadMore = async () => {};
	hasMore = false;
	constructor(private readonly callback: (rows: unknown[]) => void) {}
	getSnapshot = () => this.snapshot;
	unsubscribe = async () => {
		this.unsubscribed += 1;
	};
	push(rows: unknown[]) {
		this.snapshot = rows;
		this.callback(rows);
	}
}

class FakeListener {
	unlistened = 0;
	snapshot: unknown = undefined;
	constructor(private readonly callback: (value: unknown) => void) {}
	getSnapshot = () => this.snapshot;
	unlisten = async () => {
		this.unlistened += 1;
	};
	push(value: unknown) {
		this.snapshot = value;
		this.callback(value);
	}
}

function makeClient() {
	const querySubs: FakeSubscription[] = [];
	const listenSubs: Array<{ path: string; listener: FakeListener }> = [];
	const presenceListeners: Array<(entries: unknown[]) => void> = [];
	const presenceState = new Map<string, { userId: string; data: unknown }>();
	const actionCalls: Array<{
		name: string;
		params?: unknown;
		options?: unknown;
	}> = [];
	const eventListeners = new Map<string, Set<(...args: unknown[]) => void>>();

	let presenceUnsubscribes = 0;
	let actionImpl: (name: string, params?: unknown) => Promise<unknown> =
		async () => ({
			ok: true,
		});

	const client = {
		status: "disconnected",
		store: {
			subscribe: async (
				_collection: string,
				_options: unknown,
				callback: (rows: unknown[]) => void,
			) => {
				const subscription = new FakeSubscription(callback);
				querySubs.push(subscription);
				return subscription;
			},
			listen: async (path: string, callback: (value: unknown) => void) => {
				const listener = new FakeListener(callback);
				listenSubs.push({ path, listener });
				return listener;
			},
		},
		presence: {
			localUserId: "me",
			get: (userId: string) => presenceState.get(userId),
			set: async (data: unknown) => {
				presenceState.set("me", { userId: "me", data });
			},
			subscribe: async (callback: (entries: unknown[]) => void) => {
				presenceListeners.push(callback);
				return async () => {
					presenceUnsubscribes += 1;
				};
			},
		},
		actions: {
			call: (name: string, params?: unknown, options?: unknown) => {
				actionCalls.push({ name, params, options });
				return actionImpl(name, params);
			},
		},
		on: (event: string, callback: (...args: unknown[]) => void) => {
			let set = eventListeners.get(event);
			if (set === undefined) {
				set = new Set();
				eventListeners.set(event, set);
			}
			set.add(callback);
		},
		off: (event: string, callback: (...args: unknown[]) => void) => {
			eventListeners.get(event)?.delete(callback);
		},
		emit: (event: string, ...args: unknown[]) => {
			for (const callback of eventListeners.get(event) ?? []) {
				callback(...args);
			}
		},
	};

	return {
		client: client as unknown as ZyncBaseClient,
		querySubs,
		listenSubs,
		presenceListeners,
		presenceState,
		actionCalls,
		getPresenceUnsubscribes: () => presenceUnsubscribes,
		setActionImpl: (impl: typeof actionImpl) => {
			actionImpl = impl;
		},
	};
}

function wrapperFor(client: ZyncBaseClient) {
	return ({ children }: { children?: ReactNode }) =>
		createElement(ZyncBaseProvider, { client }, children);
}

// ─── Provider ───────────────────────────────────────────────────────────────

describe("provider", () => {
	test("hooks throw a descriptive error outside the provider", () => {
		expect(() => renderHook(() => useQuery("tasks", {}))).toThrow(
			/ZyncBaseProvider/,
		);
		expect(() => renderHook(() => useClient())).toThrow(/ZyncBaseProvider/);
	});

	test("factory returns the same binding names", () => {
		const bindings = createZyncBaseReact();
		for (const name of [
			"ZyncBaseProvider",
			"useClient",
			"useQuery",
			"useListen",
			"useAction",
			"usePresence",
			"useSyncStatus",
		] as const) {
			expect(typeof bindings[name]).toBe("function");
		}
	});
});

// ─── useQuery ───────────────────────────────────────────────────────────────

describe("useQuery", () => {
	test("triad transitions from loading to snapshot", async () => {
		const { client, querySubs } = makeClient();
		const { result } = renderHook(
			() => useQuery("tasks", { where: { done: false } }),
			{ wrapper: wrapperFor(client) },
		);

		expect(result.current.isLoading).toBe(true);
		expect(result.current.data).toEqual([]);

		await waitFor(() => expect(querySubs.length).toBe(1));
		act(() => {
			querySubs[0].push([{ id: "a" }]);
		});

		expect(result.current.isLoading).toBe(false);
		expect(result.current.data).toEqual([{ id: "a" }]);
		expect(result.current.error).toBeNull();
	});

	test("skip registers nothing and resets the triad", async () => {
		const { client, querySubs } = makeClient();
		const { result } = renderHook(() => useQuery("tasks", "skip"), {
			wrapper: wrapperFor(client),
		});

		expect(result.current).toEqual({
			data: [],
			isLoading: false,
			error: null,
		});
		expect(querySubs.length).toBe(0);
	});

	test("inline option literals do not re-subscribe", async () => {
		const { client, querySubs } = makeClient();
		const { rerender } = renderHook(
			() => useQuery("tasks", { where: { done: false } }),
			{ wrapper: wrapperFor(client) },
		);

		await waitFor(() => expect(querySubs.length).toBe(1));
		rerender();
		rerender();

		expect(querySubs.length).toBe(1);
	});

	test("changed options re-subscribe and reset to loading", async () => {
		const { client, querySubs } = makeClient();
		const { result, rerender } = renderHook(
			({ done }: { done: boolean }) => useQuery("tasks", { where: { done } }),
			{ wrapper: wrapperFor(client), initialProps: { done: false } },
		);

		await waitFor(() => expect(querySubs.length).toBe(1));
		act(() => {
			querySubs[0].push([{ id: "a" }]);
		});

		rerender({ done: true });
		expect(result.current.isLoading).toBe(true);
		expect(result.current.data).toEqual([]);

		await waitFor(() => expect(querySubs.length).toBe(2));
		await waitFor(() => expect(querySubs[0].unsubscribed).toBe(1));
	});

	test("unmount unsubscribes the handle", async () => {
		const { client, querySubs } = makeClient();
		const { unmount } = renderHook(() => useQuery("tasks", {}), {
			wrapper: wrapperFor(client),
		});

		await waitFor(() => expect(querySubs.length).toBe(1));
		unmount();
		await waitFor(() => expect(querySubs[0].unsubscribed).toBe(1));
	});

	test("registration failure lands in error without throwing", async () => {
		const { client } = makeClient();
		(
			client.store as unknown as {
				subscribe: () => Promise<never>;
			}
		).subscribe = async () => {
			throw Object.assign(new Error("nope"), { code: "FAIL" });
		};

		const { result } = renderHook(() => useQuery("tasks", {}), {
			wrapper: wrapperFor(client),
		});

		await waitFor(() => expect(result.current.error).not.toBeNull());
		expect(result.current.isLoading).toBe(false);
		expect(result.current.data).toEqual([]);
	});
});

// ─── useListen ──────────────────────────────────────────────────────────────

describe("useListen", () => {
	test("delivers the path value", async () => {
		const { client, listenSubs } = makeClient();
		const { result } = renderHook(() => useListen("users.alice.status"), {
			wrapper: wrapperFor(client),
		});

		expect(result.current.isLoading).toBe(true);
		await waitFor(() => expect(listenSubs.length).toBe(1));
		act(() => {
			listenSubs[0].listener.push("online");
		});

		expect(result.current.value).toBe("online");
		expect(result.current.isLoading).toBe(false);
	});

	test("path change re-binds and ignores late deliveries", async () => {
		const { client, listenSubs } = makeClient();
		const { result, rerender } = renderHook(
			({ path }: { path: string }) => useListen(path),
			{ wrapper: wrapperFor(client), initialProps: { path: "a" } },
		);

		await waitFor(() => expect(listenSubs.length).toBe(1));
		act(() => {
			listenSubs[0].listener.push("old-value");
		});
		expect(result.current.value).toBe("old-value");

		rerender({ path: "b" });
		expect(result.current.isLoading).toBe(true);

		await waitFor(() => expect(listenSubs.length).toBe(2));
		await waitFor(() => expect(listenSubs[0].listener.unlistened).toBe(1));

		act(() => {
			listenSubs[0].listener.push("late-old");
		});
		expect(result.current.value).toBeUndefined();

		act(() => {
			listenSubs[1].listener.push("new-value");
		});
		expect(result.current.value).toBe("new-value");
	});
});

// ─── useAction ──────────────────────────────────────────────────────────────

describe("useAction", () => {
	test("returns a stable bound caller (options from hook or call)", async () => {
		const { client, actionCalls } = makeClient();
		const { result, rerender } = renderHook(
			() => useAction("player_join", { timeoutMs: 500 }),
			{ wrapper: wrapperFor(client) },
		);

		const first = result.current;
		rerender();
		expect(result.current).toBe(first);

		await act(async () => {
			await result.current({ name: "Alice" });
		});
		expect(actionCalls[0]).toEqual({
			name: "player_join",
			params: { name: "Alice" },
			options: { timeoutMs: 500 },
		});

		await act(async () => {
			await result.current({ name: "Bob" }, { timeoutMs: 10 });
		});
		expect(actionCalls[1].options).toEqual({ timeoutMs: 10 });
	});

	test("rejections propagate to the caller", async () => {
		const { client, setActionImpl } = makeClient();
		setActionImpl(async () => {
			throw new Error("action failed");
		});
		const { result } = renderHook(() => useAction("explode"), {
			wrapper: wrapperFor(client),
		});

		await act(async () => {
			await expect(result.current()).rejects.toThrow("action failed");
		});
	});

	test("binds the actions receiver", async () => {
		const { client } = makeClient();
		const actions = client.actions as unknown as {
			call: (this: { marker: string }) => Promise<unknown>;
			marker: string;
		};
		actions.marker = "receiver";
		actions.call = function (this: { marker: string }) {
			return Promise.resolve(this.marker);
		};

		const { result } = renderHook(() => useAction("player_join"), {
			wrapper: wrapperFor(client),
		});

		await act(async () => {
			await expect(result.current({})).resolves.toBe("receiver");
		});
	});
});

// ─── usePresence ────────────────────────────────────────────────────────────

describe("usePresence", () => {
	test("shares one wire subscription, filters self, publishes", async () => {
		const {
			client,
			presenceListeners,
			presenceState,
			getPresenceUnsubscribes,
		} = makeClient();
		const seen: Array<{ tag: string; peers: unknown[]; mine: unknown }> = [];
		let publish: ((data: unknown) => Promise<void>) | undefined;

		function Consumer({ tag }: { tag: string }) {
			const presence = usePresence();
			seen.push({ tag, peers: presence.peers, mine: presence.mine });
			publish = presence.publish;
			return null;
		}

		const { unmount } = render(
			createElement(
				ZyncBaseProvider,
				{ client },
				createElement("div", null, [
					createElement(Consumer, { key: "a", tag: "a" }),
					createElement(Consumer, { key: "b", tag: "b" }),
				]),
			),
		);

		await waitFor(() => expect(presenceListeners.length).toBe(1));

		presenceState.set("me", {
			userId: "me",
			data: { status: "idle" },
		});
		presenceState.set("other", {
			userId: "other",
			data: { status: "typing" },
		});
		act(() => {
			presenceListeners[0]([
				{ userId: "me", data: { status: "idle" }, joinedAt: 0 },
				{ userId: "other", data: { status: "typing" }, joinedAt: 0 },
			]);
		});

		const latest = seen[seen.length - 1];
		expect(latest.peers).toHaveLength(1);
		expect((latest.peers[0] as { userId: string }).userId).toBe("other");
		expect((latest.mine as { userId: string }).userId).toBe("me");

		await act(async () => {
			await publish?.({ status: "typing" });
		});
		const afterPublish = seen[seen.length - 1];
		expect(
			(afterPublish.mine as { data: { status: string } }).data.status,
		).toBe("typing");

		unmount();
		await waitFor(() => expect(getPresenceUnsubscribes()).toBe(1));
	});

	test("unsubscribes after the last consumer unmounts", async () => {
		const { client, presenceListeners, getPresenceUnsubscribes } = makeClient();
		const { unmount } = renderHook(() => usePresence(), {
			wrapper: wrapperFor(client),
		});

		await waitFor(() => expect(presenceListeners.length).toBe(1));
		unmount();
		await waitFor(() => expect(getPresenceUnsubscribes()).toBe(1));
	});

	test("StrictMode unmount before ack releases every wire subscription", async () => {
		const { client, presenceListeners, getPresenceUnsubscribes } = makeClient();
		const { unmount } = renderHook(() => usePresence(), {
			wrapper: ({ children }: { children?: ReactNode }) =>
				createElement(
					StrictMode,
					null,
					createElement(ZyncBaseProvider, { client }, children),
				),
		});

		// Unmount while the subscribe acks are still pending: they resolve after
		// refs already dropped to zero, so each handle must release itself.
		const subscribeCalls = presenceListeners.length;
		expect(subscribeCalls).toBeGreaterThan(0);
		unmount();
		await waitFor(() => expect(getPresenceUnsubscribes()).toBe(subscribeCalls));
	});

	test("a failed subscribe does not poison the shared hub", async () => {
		const { client, getPresenceUnsubscribes } = makeClient();
		const presence = client.presence as unknown as {
			subscribe: (
				callback: (entries: unknown[]) => void,
			) => Promise<() => Promise<void>>;
		};
		const originalSubscribe = presence.subscribe.bind(presence);
		let subscribeCalls = 0;
		presence.subscribe = (callback) => {
			subscribeCalls += 1;
			if (subscribeCalls === 1) return Promise.reject(new Error("boom"));
			return originalSubscribe(callback);
		};

		const first = renderHook(() => usePresence(), {
			wrapper: wrapperFor(client),
		});
		await waitFor(() => expect(subscribeCalls).toBe(1));

		// The second consumer mounts while the first is still alive; without the
		// registry cleanup it would reuse the dead hub and never subscribe.
		const second = renderHook(() => usePresence(), {
			wrapper: wrapperFor(client),
		});
		await waitFor(() => expect(subscribeCalls).toBe(2));

		second.unmount();
		first.unmount();
		await waitFor(() => expect(getPresenceUnsubscribes()).toBe(1));
	});
});

// ─── useSyncStatus ──────────────────────────────────────────────────────────

describe("useSyncStatus", () => {
	test("maps status and synced events", async () => {
		const { client } = makeClient();
		const emitter = client as unknown as {
			emit: (event: string, ...args: unknown[]) => void;
		};
		const { result } = renderHook(() => useSyncStatus(), {
			wrapper: wrapperFor(client),
		});

		expect(result.current).toEqual({ status: "disconnected", synced: false });

		act(() => emitter.emit("statusChange", "connecting"));
		expect(result.current.status).toBe("connecting");

		act(() => emitter.emit("statusChange", "connected"));
		act(() => emitter.emit("synced"));
		expect(result.current).toEqual({ status: "connected", synced: true });

		act(() => emitter.emit("reconnecting", 1, 1000));
		expect(result.current.synced).toBe(false);

		act(() => emitter.emit("reconnected"));
		expect(result.current.synced).toBe(true);

		act(() => emitter.emit("disconnected", { code: "gone" }));
		expect(result.current.synced).toBe(false);
	});

	test("server render uses the disconnected default", async () => {
		const { client } = makeClient();
		const { renderToString } = await import("react-dom/server");

		function Reader() {
			const status = useSyncStatus();
			return createElement("span", null, `${status.status}:${status.synced}`);
		}

		const html = renderToString(
			createElement(ZyncBaseProvider, { client }, createElement(Reader)),
		);
		expect(html).toContain("disconnected:false");
	});
});
