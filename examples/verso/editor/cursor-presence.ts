/**
 * Tiptap publishes its selection as two `Y.RelativePosition` objects. Their
 * serialized shape is `{ type: ID?, tname?: string, item: ID?, assoc }` where
 * `ID` is `{ client, clock }`. Presence fields are typed and sparse, so both
 * directions are normalized here:
 *
 * - a position with none of `type`/`tname`/`item` is dropped: it cannot be
 *   resolved, and yjs throws `Unexpected case` when a peer tries;
 * - absent leaves are written as explicit nulls so presence's leaf-wise merge
 *   cannot resurrect a stale `item` from the previous cursor.
 */
export interface RelativeId {
	client: number;
	clock: number;
}

export interface RelativePositionJson {
	type?: RelativeId;
	tname?: string;
	item?: RelativeId;
	assoc?: number;
}

export interface PresencePosition {
	type: { client: number | null; clock: number | null };
	tname: string | null;
	item: { client: number | null; clock: number | null };
	assoc: number;
}

export interface PresenceCursor {
	anchor: PresencePosition;
	head: PresencePosition;
}

export interface AwarenessCursor {
	anchor: RelativePositionJson;
	head: RelativePositionJson;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function readId(value: unknown): RelativeId | null {
	if (!isRecord(value)) return null;
	const { client, clock } = value;
	if (
		typeof client === "number" &&
		typeof clock === "number" &&
		Number.isInteger(client) &&
		Number.isInteger(clock)
	) {
		return { client, clock };
	}
	return null;
}

function readTname(value: unknown): string | null {
	return typeof value === "string" && value.length > 0 ? value : null;
}

/** Whitelists one awareness position into a presence position. */
export function pickRelativePosition(value: unknown): PresencePosition | null {
	if (!isRecord(value)) return null;
	const type = readId(value.type);
	const tname = readTname(value.tname);
	const item = readId(value.item);
	if (!type && !tname && !item) return null;
	return {
		type: type ?? { client: null, clock: null },
		tname,
		item: item ?? { client: null, clock: null },
		assoc: typeof value.assoc === "number" ? value.assoc : 0,
	};
}

/** A cursor with no reference at all still needs to clear the previous one. */
export const CLEARED_CURSOR: PresenceCursor = {
	anchor: {
		type: { client: null, clock: null },
		tname: null,
		item: { client: null, clock: null },
		assoc: 0,
	},
	head: {
		type: { client: null, clock: null },
		tname: null,
		item: { client: null, clock: null },
		assoc: 0,
	},
};

/** Awareness state → presence payload. Both ends are needed to draw a caret. */
export function cursorToPresence(value: unknown): PresenceCursor | null {
	if (!isRecord(value)) return null;
	const anchor = pickRelativePosition(value.anchor);
	const head = pickRelativePosition(value.head);
	if (!anchor || !head) return null;
	return { anchor, head };
}

function fromPresencePosition(value: unknown): RelativePositionJson | null {
	if (!isRecord(value)) return null;
	const out: RelativePositionJson = {};
	const type = readId(value.type);
	if (type) out.type = type;
	const tname = readTname(value.tname);
	if (tname) out.tname = tname;
	const item = readId(value.item);
	if (item) out.item = item;
	if (typeof value.assoc === "number") out.assoc = value.assoc;
	if (!out.type && !out.tname && !out.item) return null;
	return out;
}

/** Presence payload → awareness state. An unusable cursor is omitted. */
export function cursorFromPresence(value: unknown): AwarenessCursor | null {
	if (!isRecord(value)) return null;
	const anchor = fromPresencePosition(value.anchor);
	const head = fromPresencePosition(value.head);
	if (!anchor || !head) return null;
	return { anchor, head };
}
