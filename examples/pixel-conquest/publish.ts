import type { BatchOperation } from "@zyncbase/client";
import { rowId } from "./shared";
import type { World } from "./world";

export const PUBLISH_BATCH_SIZE = 100;

export type PublishSnapshot = {
	chunks: number[];
	countries: number[];
	removed: number[];
};

/** Snapshot the world's dirty sets and clear them for the next tick. */
export function drainPublishState(world: World): PublishSnapshot {
	const snapshot = {
		chunks: [...world.dirtyChunks],
		countries: [...world.dirtyCountries],
		removed: [...world.dirtyRemovedCountries],
	};
	world.dirtyChunks.clear();
	world.dirtyCountries.clear();
	world.dirtyRemovedCountries.clear();
	return snapshot;
}

/** Re-queue a drained snapshot so a retry resends every uncommitted operation. */
export function restorePublishState(
	world: World,
	snapshot: PublishSnapshot,
): void {
	for (const index of snapshot.chunks) world.dirtyChunks.add(index);
	for (const code of snapshot.countries) world.dirtyCountries.add(code);
	for (const code of snapshot.removed) world.dirtyRemovedCountries.add(code);
}

/** Build committed-batch operations from a snapshot; removes go first. */
export function buildPublishOperations(
	world: World,
	snapshot: PublishSnapshot,
	extra: BatchOperation[] = [],
): BatchOperation[] {
	const countries = snapshot.countries
		.map((code) => world.countries.get(code))
		.filter((c) => c !== undefined);
	return [
		...extra,
		...snapshot.removed.map((code) => ({
			op: "remove" as const,
			path: ["countries", rowId(code)],
		})),
		...countries.map(({ id, ...value }) => ({
			op: "set" as const,
			path: ["countries", id],
			value,
		})),
		...snapshot.chunks.map((index) => {
			const { id, ...value } = world.chunk(index);
			return { op: "set" as const, path: ["chunks", id], value };
		}),
	];
}

/** Send operations in bounded slices so no message exceeds size limits. */
export async function runPublishBatches(
	batch: (operations: BatchOperation[]) => Promise<void>,
	operations: BatchOperation[],
): Promise<void> {
	for (let i = 0; i < operations.length; i += PUBLISH_BATCH_SIZE)
		await batch(operations.slice(i, i + PUBLISH_BATCH_SIZE));
}
