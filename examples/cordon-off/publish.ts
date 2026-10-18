import type { BatchOperation } from "@zyncbase/client";
import { rowId } from "./shared";
import type { World } from "./world";

// 500 is both the SDK and server batch cap. With RLE country-chunk rows plus
// at most 100 user chunks and MAX_PLAYERS dots, a slice stays well under the
// configured message cap.
export const PUBLISH_BATCH_SIZE = 500;
// Country chunks are the high-volume fan-out; movement paint is predicted by
// clients, so full rows can reconcile less often than dots move.
export const COUNTRY_CHUNK_PUBLISH_EVERY_TICKS = 3;

export type PublishSnapshot = {
	countryChunks: number[];
	userChunks: number[];
	countries: number[];
	removed: number[];
	playerRows: string[];
	removedPlayerRows: string[];
	cueCountries: number[];
	cuePlayers: string[];
};

/** The roster rows this drain carries: everything when the flush is due, only
 * the cue rows when the roster is held. Held cue rows are pulled out of the
 * dirty sets so the slower flush does not publish them twice. */
function drainRosterRows(
	world: World,
	rosters: boolean,
	cueCountries: number[],
	cuePlayers: string[],
): Pick<
	PublishSnapshot,
	"countries" | "removed" | "playerRows" | "removedPlayerRows"
> {
	if (!rosters) {
		for (const countryId of cueCountries)
			world.dirtyCountries.delete(countryId);
		for (const id of cuePlayers) world.dirtyPlayerRows.delete(id);
		return {
			countries: cueCountries,
			removed: [],
			playerRows: cuePlayers,
			removedPlayerRows: [],
		};
	}
	const rows = {
		countries: [...world.dirtyCountries],
		removed: [...world.dirtyRemovedCountries],
		playerRows: [...world.dirtyPlayerRows],
		removedPlayerRows: [...world.dirtyRemovedPlayerRows],
	};
	world.dirtyCountries.clear();
	world.dirtyRemovedCountries.clear();
	world.dirtyPlayerRows.clear();
	world.dirtyRemovedPlayerRows.clear();
	return rows;
}

/** Whether this publish pass should flush full country-chunk rows. */
export function shouldPublishCountryChunks(
	tickCount: number,
	force: boolean,
	bulkCapturePending: boolean,
): boolean {
	return (
		force ||
		bulkCapturePending ||
		tickCount % COUNTRY_CHUNK_PUBLISH_EVERY_TICKS === 0
	);
}

/** Snapshot the world's dirty sets and clear the rows this pass owns. */
export function drainPublishState(
	world: World,
	opts?: { rosters?: boolean; chunks?: boolean },
): PublishSnapshot {
	// Roster rows (countries/users) can be held back for a slower flush while
	// user chunks stay per-tick: the sets dedupe, so held entries simply publish
	// later with their latest values. Cue rows ship now either way.
	const rosters = opts?.rosters ?? true;
	const chunks = opts?.chunks ?? true;
	const cueCountries = [...world.cueCountries];
	const cuePlayers = [...world.cuePlayers];
	world.cueCountries.clear();
	world.cuePlayers.clear();
	const snapshot = {
		countryChunks: chunks ? [...world.dirtyCountryChunks] : [],
		userChunks: [...world.dirtyUserChunks],
		cueCountries,
		cuePlayers,
		...drainRosterRows(world, rosters, cueCountries, cuePlayers),
	};
	if (chunks) world.dirtyCountryChunks.clear();
	world.dirtyUserChunks.clear();
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
	for (const countryId of snapshot.cueCountries)
		world.cueCountries.add(countryId);
	for (const id of snapshot.cuePlayers) world.cuePlayers.add(id);
}

/** Build committed-batch operations from a snapshot; removes go first. */
export function buildPublishOperations(
	world: World,
	snapshot: PublishSnapshot,
	extra: BatchOperation[] = [],
): BatchOperation[] {
	// Cue rows can also sit in the bulk lists (a forced flush drains both), so
	// merge by id before building to keep each row in one operation.
	const countryIds = new Set([...snapshot.countries, ...snapshot.cueCountries]);
	const playerIds = new Set([...snapshot.playerRows, ...snapshot.cuePlayers]);
	const countries = [...countryIds]
		.map((countryId) => world.countries.get(countryId))
		.filter((c) => c !== undefined);
	// Stale tombstone expiry loses to a live rejoin: rejoins clear their
	// queued remove in spawnAt, and this filter covers any drain/build gap.
	const removedPlayerRows = snapshot.removedPlayerRows.filter(
		(id) => !world.players.has(id),
	);
	const playerRows = [...playerIds]
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
		// User chunks carry movement predictions; apply them before the
		// authoritative country snapshot so reconciliation always wins in a batch.
		...snapshot.userChunks.map((index) => {
			const { id, ...value } = world.userChunk(index);
			return { op: "set" as const, path: ["user_chunks", id], value };
		}),
		...snapshot.countryChunks.map((index) => {
			const { id, ...value } = world.countryChunk(index);
			return { op: "set" as const, path: ["country_chunks", id], value };
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
