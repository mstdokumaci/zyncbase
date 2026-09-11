import type { BatchOperation } from "@zyncbase/client";
import { rowId } from "./shared";
import type { World } from "./world";

export const PUBLISH_BATCH_SIZE = 100;

export type PublishSnapshot = {
	chunks: number[];
	countries: number[];
	removed: number[];
	users: string[];
	removedUsers: string[];
};

/** Snapshot the world's dirty sets and clear them for the next tick. */
export function drainPublishState(
	world: World,
	opts?: { rosters?: boolean },
): PublishSnapshot {
	// Roster rows (countries/users) can be held back for a slower flush while
	// chunks stay per-tick: the sets dedupe, so held entries simply publish
	// later with their latest values.
	const rosters = opts?.rosters ?? true;
	const snapshot = {
		chunks: [...world.dirtyChunks],
		countries: rosters ? [...world.dirtyCountries] : [],
		removed: rosters ? [...world.dirtyRemovedCountries] : [],
		users: rosters ? [...world.dirtyUsers] : [],
		removedUsers: rosters ? [...world.dirtyRemovedUsers] : [],
	};
	world.dirtyChunks.clear();
	if (rosters) {
		world.dirtyCountries.clear();
		world.dirtyRemovedCountries.clear();
		world.dirtyUsers.clear();
		world.dirtyRemovedUsers.clear();
	}
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
	for (const id of snapshot.users) world.dirtyUsers.add(id);
	for (const id of snapshot.removedUsers) world.dirtyRemovedUsers.add(id);
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
	// Stale tombstone expiry loses to a live rejoin: rejoins clear their
	// queued remove in spawnAt, and this filter covers any drain/build gap.
	const removedUsers = snapshot.removedUsers.filter(
		(id) => !world.players.has(id),
	);
	const users = snapshot.users
		.map((id) => ({ id, row: world.userRow(id) }))
		.filter((entry) => entry.row !== undefined);
	return [
		...extra,
		...snapshot.removed.map((code) => ({
			op: "remove" as const,
			path: ["countries", rowId(code)],
		})),
		...removedUsers.map((id) => ({
			op: "remove" as const,
			path: ["users", id],
		})),
		...countries.map(({ id, ...value }) => ({
			op: "set" as const,
			path: ["countries", id],
			value,
		})),
		...users.map(({ id, row }) => ({
			op: "set" as const,
			path: ["users", id],
			value: row,
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
