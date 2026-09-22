import type { BatchOperation } from "@zyncbase/client";
import { rowId } from "./shared";
import type { World } from "./world";

// 500 is both the SDK and server batch cap. With RLE country-chunk rows plus
// at most 100 user chunks and MAX_PLAYERS dots, a slice stays well under the
// configured message cap.
export const PUBLISH_BATCH_SIZE = 500;

export type PublishSnapshot = {
	countryChunks: number[];
	userChunks: number[];
	countries: number[];
	removed: number[];
	playerRows: string[];
	removedPlayerRows: string[];
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
		countryChunks: [...world.dirtyCountryChunks],
		userChunks: [...world.dirtyUserChunks],
		countries: rosters ? [...world.dirtyCountries] : [],
		removed: rosters ? [...world.dirtyRemovedCountries] : [],
		playerRows: rosters ? [...world.dirtyPlayerRows] : [],
		removedPlayerRows: rosters ? [...world.dirtyRemovedPlayerRows] : [],
	};
	world.dirtyCountryChunks.clear();
	world.dirtyUserChunks.clear();
	if (rosters) {
		world.dirtyCountries.clear();
		world.dirtyRemovedCountries.clear();
		world.dirtyPlayerRows.clear();
		world.dirtyRemovedPlayerRows.clear();
	}
	return snapshot;
}

/** Re-queue a drained snapshot so a retry resends every uncommitted operation. */
export function restorePublishState(
	world: World,
	snapshot: PublishSnapshot,
): void {
	for (const index of snapshot.countryChunks)
		world.dirtyCountryChunks.add(index);
	for (const index of snapshot.userChunks) world.dirtyUserChunks.add(index);
	for (const countryId of snapshot.countries)
		world.dirtyCountries.add(countryId);
	for (const countryId of snapshot.removed)
		world.dirtyRemovedCountries.add(countryId);
	for (const id of snapshot.playerRows) world.dirtyPlayerRows.add(id);
	for (const id of snapshot.removedPlayerRows)
		world.dirtyRemovedPlayerRows.add(id);
}

/** Build committed-batch operations from a snapshot; removes go first. */
export function buildPublishOperations(
	world: World,
	snapshot: PublishSnapshot,
	extra: BatchOperation[] = [],
): BatchOperation[] {
	const countries = snapshot.countries
		.map((countryId) => world.countries.get(countryId))
		.filter((c) => c !== undefined);
	// Stale tombstone expiry loses to a live rejoin: rejoins clear their
	// queued remove in spawnAt, and this filter covers any drain/build gap.
	const removedPlayerRows = snapshot.removedPlayerRows.filter(
		(id) => !world.players.has(id),
	);
	const playerRows = snapshot.playerRows
		.map((id) => ({ id, row: world.playerRow(id) }))
		.filter((entry) => entry.row !== undefined);
	return [
		...extra,
		...snapshot.removed.map((countryId) => ({
			op: "remove" as const,
			path: ["countries", rowId(countryId)],
		})),
		...removedPlayerRows.map((id) => ({
			op: "remove" as const,
			path: ["users", id],
		})),
		...countries.map((country) => ({
			op: "set" as const,
			path: ["countries", rowId(country.country_id)],
			value: country,
		})),
		...playerRows.map(({ id, row }) => ({
			op: "set" as const,
			path: ["users", id],
			value: row,
		})),
		...snapshot.countryChunks.map((index) => {
			const { id, ...value } = world.countryChunk(index);
			return { op: "set" as const, path: ["country_chunks", id], value };
		}),
		...snapshot.userChunks.map((index) => {
			const { id, ...value } = world.userChunk(index);
			return { op: "set" as const, path: ["user_chunks", id], value };
		}),
	];
}

/** Send every slice without waiting for earlier acknowledgements. The
 * connection sends synchronously in order and the write worker commits FIFO,
 * so removes still land before sets; all slices are awaited before returning. */
export async function runPublishBatches(
	batch: (operations: BatchOperation[]) => Promise<void>,
	operations: BatchOperation[],
): Promise<void> {
	const slices: BatchOperation[][] = [];
	for (let i = 0; i < operations.length; i += PUBLISH_BATCH_SIZE)
		slices.push(operations.slice(i, i + PUBLISH_BATCH_SIZE));
	const results = await Promise.allSettled(
		slices.map((slice) => {
			try {
				return batch(slice);
			} catch (error) {
				return Promise.reject(error);
			}
		}),
	);
	for (const result of results)
		if (result.status === "rejected") throw result.reason;
}
