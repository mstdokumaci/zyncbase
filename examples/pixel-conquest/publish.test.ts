import { expect, test } from "bun:test";
import type { BatchOperation } from "@zyncbase/client";
import {
	buildPublishOperations,
	drainPublishState,
	restorePublishState,
	runPublishBatches,
} from "./publish";
import { HEIGHT, WIDTH } from "./shared";
import { World } from "./world";

test("a rejected batch restores every drained entry so retry resends all", async () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	world.input(
		"keeper",
		{
			name: "Keeper",
			direction: "idle",
			countryCode: world.country("Keep")?.code,
			seq: 1,
			sentAt: 0,
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
			sentAt: 0,
		},
		0,
	);
	world.remove("ghost");
	const ghost = [...world.dirtyRemovedCountries];
	expect(ghost).toHaveLength(1);
	// More than one 100-operation batch of chunk writes.
	for (let i = 0; i < 120; i++) world.dirtyChunks.add(i);
	const snapshot = drainPublishState(world);
	expect(world.dirtyChunks.size).toBe(0);
	expect(world.dirtyCountries.size).toBe(0);
	expect(world.dirtyRemovedCountries.size).toBe(0);
	const operations = buildPublishOperations(world, snapshot);
	expect(operations.length).toBeGreaterThan(100);
	expect(operations[0]).toEqual({
		op: "remove",
		path: ["countries", String(ghost[0])],
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
});
