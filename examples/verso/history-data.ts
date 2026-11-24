import type { ChangeRow } from "./shared";

export interface ChangeEntry {
	at: number;
	bytes: Uint8Array;
}

/**
 * Rebuilds the page's change log from its chunked rows. Single-part payloads
 * are complete on arrival; multi-part payloads need every part plus a commit
 * row, exactly as the provider wrote them.
 */
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: chunk validation is a linear parser with explicit guards.
export function assembleChanges(rows: readonly ChangeRow[]): ChangeEntry[] {
	const pending = new Map<
		string,
		{
			parts: number;
			chunks: Map<number, Uint8Array>;
			committed: boolean;
			at: number;
		}
	>();
	const entries: ChangeEntry[] = [];
	for (const row of rows) {
		if (row.parts === 1) {
			if (row.data) entries.push({ at: row.created_at ?? 0, bytes: row.data });
			continue;
		}
		let group = pending.get(row.update_id);
		if (!group) {
			group = {
				parts: row.parts,
				chunks: new Map(),
				committed: false,
				at: row.created_at ?? 0,
			};
			pending.set(row.update_id, group);
		}
		if (row.part === row.parts) {
			if (row.committed === true) group.committed = true;
		} else if (row.data) {
			group.chunks.set(row.part, row.data);
		}
		if (group.committed && group.chunks.size === group.parts) {
			const bytes = new Uint8Array(
				[...group.chunks.values()].reduce((sum, part) => sum + part.length, 0),
			);
			let offset = 0;
			for (let index = 0; index < group.parts; index += 1) {
				const part = group.chunks.get(index);
				if (!part) break;
				bytes.set(part, offset);
				offset += part.length;
			}
			entries.push({ at: group.at, bytes });
			pending.delete(row.update_id);
		}
	}
	return entries;
}
