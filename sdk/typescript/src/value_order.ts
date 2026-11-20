import { compareDocIds } from "./doc_id.js";
import type { JsonValue } from "./types.js";

const textEncoder = new TextEncoder();

/**
 * Orders two non-null scalars as the server does: numbers numerically,
 * strings by UTF-8 bytes (packed order when `docId`), booleans
 * false < true. Values of different types compare equal.
 */
export function compareScalars(
	a: JsonValue,
	b: JsonValue,
	docId: boolean,
): number {
	if (typeof a !== typeof b) return 0;
	switch (typeof a) {
		case "number":
			return compareAsc(a, b as number);
		case "boolean":
			return a === b ? 0 : a ? 1 : -1;
		case "string":
			return docId
				? compareDocIds(a, b as string)
				: compareUtf8(a, b as string);
		default:
			return 0;
	}
}

/** Exact scalar equality: numbers by value (0 equals -0), bytes by content. */
export function scalarsEqual(a: JsonValue, b: JsonValue): boolean {
	if (a === b) return true;
	if (!(a instanceof Uint8Array) || !(b instanceof Uint8Array)) return false;
	if (a.length !== b.length) return false;
	for (let i = 0; i < a.length; i += 1) {
		if (a[i] !== b[i]) return false;
	}
	return true;
}

/** The server's array form: sorted by `compareScalars`, exact duplicates removed. */
export function sortedSet(
	items: readonly JsonValue[],
	docId: boolean,
): JsonValue[] {
	const sorted = [...items].sort((a, b) => compareScalars(a, b, docId));
	return sorted.filter(
		(item, i) => i === 0 || !scalarsEqual(item, sorted[i - 1]),
	);
}

/** Compares strings by the exact UTF-8 bytes used by SQLite BINARY ordering. */
export function compareUtf8(a: string, b: string): number {
	if (isUtf8LexicalFastPath(a) && isUtf8LexicalFastPath(b)) {
		return compareAsc(a, b);
	}
	return compareUtf8Bytes(a, b);
}

function compareAsc<T extends number | string>(a: T, b: T): number {
	return a < b ? -1 : a > b ? 1 : 0;
}

function compareUtf8Bytes(a: string, b: string): number {
	const ba = textEncoder.encode(a);
	const bb = textEncoder.encode(b);
	const length = Math.min(ba.length, bb.length);
	for (let i = 0; i < length; i++) {
		if (ba[i] !== bb[i]) return ba[i] < bb[i] ? -1 : 1;
	}
	return ba.length < bb.length ? -1 : ba.length > bb.length ? 1 : 0;
}

function isUtf8LexicalFastPath(value: string): boolean {
	for (let i = 0; i < value.length; i += 1) {
		if (value.charCodeAt(i) >= 0x800) return false;
	}
	return true;
}
