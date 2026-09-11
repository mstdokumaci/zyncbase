import { expect, test } from "bun:test";
import assert from "node:assert/strict";
import type { BatchOperation } from "@zyncbase/client";
import {
	buildPublishOperations,
	drainPublishState,
	PUBLISH_BATCH_SIZE,
	restorePublishState,
	runPublishBatches,
} from "./publish";
import { HEIGHT, MAX_PLAYERS, WIDTH } from "./shared";
import { World } from "./world";

test("a chunk's dots cap can hold every player in one chunk", async () => {
	const schema = (await Bun.file(
		new URL("./schema.json", import.meta.url),
	).json()) as {
		store: { chunks: { fields: { dots: { maxLength: number } } } };
	};
	const cap = schema.store.chunks.fields.dots.maxLength;
	// Worst case: MAX_PLAYERS dots in one 32x32 chunk, with identity at its
	// longest plausible shape plus coordinates.
	const dot = JSON.stringify({
		player_id: "player:".padEnd(64, "0"),
		x: 9999,
		y: 9999,
	});
	assert.ok(
		cap >= dot.length * MAX_PLAYERS,
		`dots cap ${cap} < ${dot.length * MAX_PLAYERS} needed for ${MAX_PLAYERS} players in one chunk`,
	);
});

test("a chunks-only drain holds roster rows back for the slower flush", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	const code = world.country("Hold")?.code;
	assert(code);
	world.dirtyChunks.add(7);
	const partial = drainPublishState(world, { rosters: false });
	expect(partial.chunks).toEqual([7]);
	expect(partial.countries).toEqual([]);
	expect(partial.users).toEqual([]);
	expect(world.dirtyChunks.size).toBe(0);
	// Held entries keep their latest values until the roster flush drains them.
	expect(world.dirtyCountries.has(code)).toBe(true);
	const full = drainPublishState(world);
	expect(full.countries).toEqual([code]);
	expect(world.dirtyCountries.size).toBe(0);
	expect(buildPublishOperations(world, full)).toContainEqual({
		op: "set",
		path: ["countries", String(code)],
		value: { code, name: "Hold", color: "#ef4444", count: 0, is_bot: false },
	});
});
test("a rejected batch restores every drained entry so retry resends all", async () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	world.input(
		"keeper",
		{
			name: "Keeper",
			direction: "idle",
			countryCode: world.country("Keep")?.code,
			seq: 1,
		},
		0,
	);
	world.input(
		"ghost",
		{
			name: "Ghost",
			direction: "idle",
			countryCode: world.country("Ghost")?.code,
			seq: 1,
		},
		0,
	);
	world.remove("ghost", 0);
	const ghost = [...world.dirtyRemovedCountries];
	expect(ghost).toHaveLength(1);
	// The ghost's dots vanish but its roster row lingers as a tombstone.
	expect(world.dirtyUsers.has("keeper")).toBe(true);
	expect(world.dirtyUsers.has("ghost")).toBe(true);
	expect(world.dirtyRemovedUsers.size).toBe(0);
	// More than one 500-operation batch of chunk writes.
	for (let i = 0; i < 520; i++) world.dirtyChunks.add(i);
	const snapshot = drainPublishState(world);
	expect(world.dirtyChunks.size).toBe(0);
	expect(world.dirtyCountries.size).toBe(0);
	expect(world.dirtyRemovedCountries.size).toBe(0);
	expect(world.dirtyUsers.size).toBe(0);
	expect(world.dirtyRemovedUsers.size).toBe(0);
	expect(new Set(snapshot.users)).toEqual(new Set(["keeper", "ghost"]));
	const operations = buildPublishOperations(world, snapshot);
	expect(operations.length).toBeGreaterThan(100);
	expect(operations[0]).toEqual({
		op: "remove",
		path: ["countries", String(ghost[0])],
	});
	expect(operations).toContainEqual({
		op: "set",
		path: ["users", "keeper"],
		value: world.userRow("keeper"),
	});
	expect(operations).toContainEqual({
		op: "set",
		path: ["users", "ghost"],
		value: world.userRow("ghost"),
	});

	const sent: BatchOperation[][] = [];
	let calls = 0;
	const flaky = async (batch: BatchOperation[]) => {
		calls++;
		sent.push(batch);
		if (calls === 2) throw new Error("commit failed");
	};
	// Mirror server publish(): a rejected batch restores the snapshot.
	try {
		await runPublishBatches(flaky, operations);
		expect.unreachable("batch should have rejected");
	} catch (error) {
		expect(String(error)).toContain("commit failed");
		restorePublishState(world, snapshot);
	}
	// Nothing sent or unsent is lost: the failed attempt restores it all.
	expect(sent).toHaveLength(2);
	expect(world.dirtyChunks.size).toBe(snapshot.chunks.length);
	expect(world.dirtyCountries.size).toBe(snapshot.countries.length);
	expect(world.dirtyRemovedCountries).toEqual(new Set(snapshot.removed));
	expect(world.dirtyUsers).toEqual(new Set(snapshot.users));
	expect(world.dirtyRemovedUsers).toEqual(new Set(snapshot.removedUsers));

	const retried: BatchOperation[][] = [];
	const retry = async (batch: BatchOperation[]) => {
		retried.push(batch);
	};
	const retrySnapshot = drainPublishState(world);
	await runPublishBatches(retry, buildPublishOperations(world, retrySnapshot));
	expect(retried.flat()).toEqual(operations);
	expect(world.dirtyChunks.size).toBe(0);
	expect(world.dirtyCountries.size).toBe(0);
	expect(world.dirtyRemovedCountries.size).toBe(0);
	expect(world.dirtyUsers.size).toBe(0);
	expect(world.dirtyRemovedUsers.size).toBe(0);
});

test("every slice is dispatched before the first one settles", async () => {
	const operations: BatchOperation[] = Array.from(
		{ length: PUBLISH_BATCH_SIZE + 1 },
		(_, i) => ({
			op: "set" as const,
			path: ["chunks", String(i)],
			value: { owners: new Uint8Array(2), dots: new Uint8Array(0) },
		}),
	);
	const started: number[] = [];
	let release: (() => void) | undefined;
	const gate = new Promise<void>((resolve) => {
		release = resolve;
	});
	const pending = runPublishBatches(async (slice) => {
		started.push(slice.length);
		if (started.length === 1) await gate;
	}, operations);
	// Slices are mapped synchronously, so the second is in flight while the
	// first is still blocked; a serial implementation would only see the first.
	expect(started).toEqual([PUBLISH_BATCH_SIZE, 1]);
	release?.();
	await pending;
});

test("a synchronously throwing batch still settles every slice", async () => {
	const operations: BatchOperation[] = Array.from(
		{ length: PUBLISH_BATCH_SIZE * 2 + 1 },
		(_, i) => ({
			op: "set" as const,
			path: ["chunks", String(i)],
			value: { owners: new Uint8Array(2), dots: new Uint8Array(0) },
		}),
	);
	const invoked: number[] = [];
	let firstSettled = false;
	// Deliberately non-async: a synchronous throw must not abort the map and
	// skip later slices or the pending first slice.
	const pending = runPublishBatches((slice) => {
		invoked.push(slice.length);
		if (invoked.length === 2) throw new Error("sync batch failure");
		if (invoked.length === 1)
			return new Promise<void>((resolve) =>
				setTimeout(() => {
					firstSettled = true;
					resolve();
				}, 10),
			);
		return Promise.resolve();
	}, operations);
	await expect(pending).rejects.toThrow("sync batch failure");
	expect(invoked).toEqual([PUBLISH_BATCH_SIZE, PUBLISH_BATCH_SIZE, 1]);
	expect(firstSettled).toBe(true);
});
