import { describe, expect, test } from "bun:test";
import type { ZyncBaseClient } from "@zyncbase/client";
import type { ZyncBaseSchema } from "./schema-types";
import {
	COUNTRY_CHUNK_WIDTH,
	COUNTRY_COLUMNS,
	type Direction,
	HEIGHT,
	WATER_COUNTRY_CHUNKS,
	WIDTH,
} from "./shared";
import {
	COUNTRY_GRID,
	FRAME_MS,
	INITIAL_CAMERA,
	ownerAt,
	sendPlayerMove,
	subscriptionKey,
	USER_GRID,
	type Viewport,
	ViewportSubscriptions,
	ViewSession,
	visibleChunks,
} from "./viewport";

function view(
	x: number,
	y: number,
	direction: Direction = "idle",
	prefetchDirection: Direction = "idle",
): Viewport {
	return {
		x,
		y,
		width: 1440,
		height: 900,
		scale: 8,
		direction,
		prefetchDirection,
	};
}

type FakeListen = { index: number; callback: (row: unknown) => void };

function fakeStore() {
	const listens: FakeListen[] = [];
	const unlistened: number[] = [];
	// Every listen call including rejected ones, in order: path joined as
	// "table/id". Lets a test name the chunk that a one-shot rejection hit.
	const attempts: string[] = [];
	let rejectNext = false;
	const store = {
		listen(_path: unknown, callback: (row: unknown) => void) {
			attempts.push(Array.isArray(_path) ? _path.join("/") : String(_path));
			const index = listens.length;
			if (rejectNext) {
				rejectNext = false;
				return Promise.reject(new Error("listen rejected"));
			}
			listens.push({ index, callback });
			return Promise.resolve({
				unlisten: () => {
					unlistened.push(index);
					return Promise.resolve();
				},
			});
		},
	} as unknown as ZyncBaseClient<ZyncBaseSchema>["store"];
	return {
		store,
		listens,
		unlistened,
		attempts,
		rejectNext: () => {
			rejectNext = true;
		},
	};
}

function sessionOptions(
	store: ZyncBaseClient<ZyncBaseSchema>["store"],
	client?: unknown,
	onConfirmed?: () => void,
) {
	const received: unknown[] = [];
	return {
		received,
		options: {
			store: () => store,
			sinks: {
				country: { receive: (row: unknown) => received.push(row) },
				user: { receive: (row: unknown) => received.push(row) },
			},
			width: 1440,
			height: 900,
			scale: 8,
			land: new Uint8Array(WIDTH * HEIGHT),
			ownerAt: () => 0,
			isOnline: () => true,
			client: () => client as ZyncBaseClient<ZyncBaseSchema> | undefined,
			onConfirmed,
		},
	};
}

describe("viewport keys", () => {
	test("key holds for sub-chunk moves and flips at an edge crossing", () => {
		expect(subscriptionKey(COUNTRY_GRID, view(100, 100))).toBe(
			subscriptionKey(COUNTRY_GRID, view(105, 100)),
		);
		expect(subscriptionKey(COUNTRY_GRID, view(105, 100))).not.toBe(
			subscriptionKey(COUNTRY_GRID, view(115, 100)),
		);
	});

	test("heading prefetch changes the leading-edge key only", () => {
		expect(subscriptionKey(COUNTRY_GRID, view(100, 100, "right"))).not.toBe(
			subscriptionKey(COUNTRY_GRID, view(100, 100, "idle")),
		);
		expect(subscriptionKey(COUNTRY_GRID, view(100, 100, "right"))).not.toBe(
			subscriptionKey(COUNTRY_GRID, view(100, 100, "left")),
		);
	});
});

describe("visibleChunks", () => {
	test("wraps the horizontal seam into the right world copy", () => {
		// xMin = -80 < 0: the walk must add columns from the right world copy.
		const seamGrid = {
			width: 50,
			height: 25,
			columns: 40,
			rows: 40,
			prefetch: 0,
		};
		const visible = visibleChunks(seamGrid, view(10, 500));
		const rows = new Set(
			[...visible].map((index) => Math.floor(index / seamGrid.columns)),
		);
		expect(rows.size).toBeGreaterThan(0);
		for (const row of rows)
			expect(visible.has(row * seamGrid.columns + (seamGrid.columns - 1))).toBe(
				true,
			);
	});

	test("filters water-only country chunks", () => {
		const visible = visibleChunks(COUNTRY_GRID, view(275, 12));
		expect(visible.size).toBeGreaterThan(0);
		for (const index of visible) {
			expect(WATER_COUNTRY_CHUNKS[index]).toBe(0);
		}
	});

	test("clamps vertical bounds at the map edge", () => {
		const visible = visibleChunks(USER_GRID, view(1000, 5));
		for (const index of visible)
			expect(index).toBeLessThan(USER_GRID.rows * USER_GRID.columns);
	});
});

describe("ViewportSubscriptions", () => {
	test("listens once per visible chunk and reuses them until the key moves", () => {
		const { store, listens } = fakeStore();
		const subs = new ViewportSubscriptions(() => store, {
			country: { receive: () => {} },
			user: { receive: () => {} },
		});
		subs.update(view(100, 100));
		const first = listens.length;
		expect(first).toBeGreaterThan(0);
		subs.update(view(105, 100));
		expect(listens.length).toBe(first);
		subs.update(view(115, 100));
		expect(listens.length).toBeGreaterThan(first);
	});

	test("ignores late deltas after a chunk left the ring", async () => {
		const { store, listens } = fakeStore();
		let received = 0;
		const subs = new ViewportSubscriptions(() => store, {
			country: { receive: () => received++ },
			user: { receive: () => received++ },
		});
		subs.update(view(100, 100));
		const first = listens[0];
		first.callback({ id: "0" });
		expect(received).toBe(1);
		// Move far enough that the first chunk leaves the ring, then replay its
		// callback: the guard must drop it.
		subs.update(view(1500, 900));
		first.callback({ id: "0" });
		expect(received).toBe(1);
	});

	test("a rejected listen forces a resync on the next update", async () => {
		const { store, listens, rejectNext } = fakeStore();
		const subs = new ViewportSubscriptions(() => store, {
			country: { receive: () => {} },
			user: { receive: () => {} },
		});
		rejectNext();
		subs.update(view(100, 100));
		const afterFirst = listens.length;
		await Promise.resolve();
		await Promise.resolve();
		subs.update(view(100, 100));
		expect(listens.length).toBe(afterFirst + 1);
	});

	test("a stale rejection does not drop a replacement listen", async () => {
		const { store, attempts, rejectNext } = fakeStore();
		const subs = new ViewportSubscriptions(() => store, {
			country: { receive: () => {} },
			user: { receive: () => {} },
		});
		rejectNext();
		subs.update(view(100, 100));
		// The country grid syncs first, so the rejected attempt names a
		// country chunk; derive a view that excludes it.
		const rejected = attempts[0];
		expect(rejected.startsWith("country_chunks/")).toBe(true);
		const chunkX =
			(Number(rejected.split("/")[1]) % COUNTRY_COLUMNS) * COUNTRY_CHUNK_WIDTH;
		// Leave the ring and re-enter before the rejection handler can run.
		subs.update(view(chunkX + 1200, 100));
		subs.update(view(100, 100));
		const registered = subs.count;
		expect(attempts.filter((path) => path === rejected)).toHaveLength(2);
		// Drain the microtask queue: the stale rejection must not remove the
		// replacement subscription (registered) nor request a resync.
		await Promise.resolve();
		await Promise.resolve();
		expect(subs.count).toBe(registered);
		expect(attempts.filter((path) => path === rejected)).toHaveLength(2);
		subs.update(view(100, 100));
		expect(attempts.filter((path) => path === rejected)).toHaveLength(2);
	});
});

describe("ViewSession", () => {
	test("sends a move only when the direction changes", async () => {
		const { store } = fakeStore();
		const calls: { direction: string; seq: number }[] = [];
		const client = {
			actions: {
				call: (_name: string, args: { direction: string; seq: number }) => {
					calls.push(args);
					return Promise.resolve();
				},
			},
		};
		const { options } = sessionOptions(store, client);
		const session = new ViewSession(options);

		session.setDirection("right");
		session.setDirection("right");
		expect(calls).toEqual([{ direction: "right", seq: 1 }]);
		session.setDirection("down");
		expect(calls[1]).toEqual({ direction: "down", seq: 2 });
		session.release();
		expect(calls[2]).toEqual({ direction: "idle", seq: 3 });
		session.release();
		expect(calls.length).toBe(3);
	});

	test("snaps the camera on admit and eases it toward the predicted dot", () => {
		const { store } = fakeStore();
		const { options } = sessionOptions(store);
		const session = new ViewSession(options);
		session.admit({ x: 500, y: 500 });
		expect(session.camera).toEqual({ x: 500.5, y: 500.5 });
		session.receiveSelf({ x: 502, y: 500, slot: 1, colorIndex: 0 }, 0);
		// First due frame: the camera eases from the snap toward the dot.
		expect(session.frame(100).due).toBe(true);
		expect(session.camera.x).toBeLessThan(502.5);
		expect(session.camera.x).toBeGreaterThan(500.5);
		expect(session.camera.y).toBe(500.5);
	});

	test("frame gate holds between FRAME_MS boundaries", () => {
		const { store } = fakeStore();
		const { options } = sessionOptions(store);
		const session = new ViewSession(options);
		session.admit(); // INITIAL_CAMERA
		expect(session.camera).toEqual(INITIAL_CAMERA);
		expect(session.frame(FRAME_MS).due).toBe(true);
		expect(session.frame(FRAME_MS * 1.5).due).toBe(false);
	});

	test("fires onConfirmed only for a consistent move", () => {
		const { store } = fakeStore();
		let confirmed = 0;
		const { options } = sessionOptions(store, undefined, () => confirmed++);
		const session = new ViewSession(options);
		session.admit({ x: 500, y: 500 });
		session.setDirection("right");
		session.receiveSelf({ x: 500, y: 500, slot: 1, colorIndex: 0 }, 0);
		session.receiveSelf({ x: 501, y: 500, slot: 1, colorIndex: 0 }, 16);
		expect(confirmed).toBe(1);
		// A sideways jump is not a consistent rightward move.
		session.receiveSelf({ x: 501, y: 502, slot: 1, colorIndex: 0 }, 32);
		expect(confirmed).toBe(1);
	});

	test("refreshes the motion color without a relocation", () => {
		const { store } = fakeStore();
		const { options } = sessionOptions(store);
		const session = new ViewSession(options);
		session.admit({ x: 500, y: 500 });
		session.receiveSelf({ x: 500, y: 500, slot: 1, colorIndex: 0 }, 0);
		session.refreshColor(7, 16);
		expect(session.motion?.dot.colorIndex).toBe(7);
	});
});

describe("ownerAt", () => {
	test("answers water without a chunk and reads palette codes otherwise", () => {
		const land = new Uint8Array(WIDTH * HEIGHT).fill(1);
		land[500 * WIDTH + 500] = 0;
		const chunks = new Map([
			[
				Math.floor(500 / 50) + Math.floor(500 / 25) * COUNTRY_COLUMNS,
				{
					colorIndexes: new Uint8Array(50 * 25).fill(3),
				},
			],
		]);
		expect(ownerAt(chunks, land, 500, 500)).toBe(0);
		expect(ownerAt(chunks, land, 501, 500)).toBe(3);
		expect(ownerAt(chunks, land, 1, 1)).toBeUndefined();
	});
});

describe("sendPlayerMove", () => {
	test("retries a failed send while current", async () => {
		let attempts = 0;
		const client = {
			actions: {
				call: () => {
					attempts++;
					return attempts === 1
						? Promise.reject(new Error("transient"))
						: Promise.resolve();
				},
			},
		} as unknown as ZyncBaseClient<ZyncBaseSchema>;
		sendPlayerMove(client, "right", 1, () => true, 5);
		await new Promise((resolve) => setTimeout(resolve, 25));
		expect(attempts).toBe(2);
	});

	test("stops retrying once stale", async () => {
		let attempts = 0;
		const client = {
			actions: {
				call: () => {
					attempts++;
					return Promise.reject(new Error("transient"));
				},
			},
		} as unknown as ZyncBaseClient<ZyncBaseSchema>;
		sendPlayerMove(client, "right", 1, () => false, 5);
		await new Promise((resolve) => setTimeout(resolve, 25));
		expect(attempts).toBe(1);
	});
});
