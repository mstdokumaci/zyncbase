import { ErrorCodes, ZyncBaseError } from "./errors.js";

export const DOC_ID_BYTE_LENGTH = 16;
export const SHORT_ID_MAX_LENGTH = 24;
export const SHORT_ID_ALPHABET = "-0123456789_abcdefghijklmnopqrstuvwxyz";

const SHORT_BASE = 39n;
const SHORT_DIGITS = 24;
const UUID_FAMILY_TAG = 1n << 127n;
const UUID_V7_REGEX =
	/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const DOC_ID_CACHE_LIMIT = 4096;
const shortDocIdDecodeCache = new Map<bigint, string>();
const docIdSortFamilyCache = new Map<string, 0 | 1 | 2>();
const uuidDecodeCache: Array<{ packed: Uint8Array; id: string } | undefined> =
	new Array(DOC_ID_CACHE_LIMIT);

const shortCharToDigit = new Map<string, number>(
	Array.from(SHORT_ID_ALPHABET, (char, index) => [char, index + 1]),
);

function invalidDocIdError(message: string, code: string): ZyncBaseError {
	return new ZyncBaseError(message, {
		code,
		category: code === ErrorCodes.INVALID_PATH ? "client" : "validation",
		retryable: false,
	});
}

function bytesToBigInt(bytes: Uint8Array): bigint {
	// DataView 2×64 vs 16× loop — 7x faster for short path (20ms vs 143ms)
	const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
	const hi = view.getBigUint64(0, false);
	const lo = view.getBigUint64(8, false);
	return (hi << 64n) | lo;
}

function bigIntToBytes(value: bigint): Uint8Array {
	const bytes = new Uint8Array(DOC_ID_BYTE_LENGTH);
	let remaining = value;
	for (let i = DOC_ID_BYTE_LENGTH - 1; i >= 0; i -= 1) {
		bytes[i] = Number(remaining & 0xffn);
		remaining >>= 8n;
	}
	return bytes;
}

function parseUuidBytes(uuid: string): Uint8Array {
	const hex = uuid.replaceAll("-", "");
	const bytes = new Uint8Array(DOC_ID_BYTE_LENGTH);
	for (let i = 0; i < DOC_ID_BYTE_LENGTH; i += 1) {
		bytes[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
	}
	return bytes;
}

const HEX2 = (() => {
	const table: string[] = new Array(256);
	for (let i = 0; i < 256; i += 1) {
		table[i] = i.toString(16).padStart(2, "0");
	}
	return table;
})();

function formatUuidBytes(bytes: Uint8Array): string {
	return (
		HEX2[bytes[0]] +
		HEX2[bytes[1]] +
		HEX2[bytes[2]] +
		HEX2[bytes[3]] +
		"-" +
		HEX2[bytes[4]] +
		HEX2[bytes[5]] +
		"-" +
		HEX2[bytes[6]] +
		HEX2[bytes[7]] +
		"-" +
		HEX2[bytes[8]] +
		HEX2[bytes[9]] +
		"-" +
		HEX2[bytes[10]] +
		HEX2[bytes[11]] +
		HEX2[bytes[12]] +
		HEX2[bytes[13]] +
		HEX2[bytes[14]] +
		HEX2[bytes[15]]
	);
}

function encodeShortDocId(id: string): Uint8Array {
	let value = 0n;
	for (let i = 0; i < SHORT_DIGITS; i += 1) {
		const digit = i < id.length ? (shortCharToDigit.get(id[i]) ?? 0) : 0;
		value = value * SHORT_BASE + BigInt(digit);
	}
	return bigIntToBytes(value);
}

function decodeShortDocId(value: bigint): string {
	const digits = new Array<number>(SHORT_DIGITS).fill(0);
	let remaining = value;
	for (let i = SHORT_DIGITS - 1; i >= 0; i -= 1) {
		digits[i] = Number(remaining % SHORT_BASE);
		remaining /= SHORT_BASE;
	}
	if (remaining !== 0n || digits[0] === 0) {
		throw invalidDocIdError(
			"Invalid packed short document ID",
			ErrorCodes.INVALID_MESSAGE,
		);
	}

	let result = "";
	let seenEnd = false;
	for (const digit of digits) {
		if (digit === 0) {
			seenEnd = true;
			continue;
		}
		if (seenEnd) {
			throw invalidDocIdError(
				"Invalid non-canonical short document ID",
				ErrorCodes.INVALID_MESSAGE,
			);
		}
		result += SHORT_ID_ALPHABET[digit - 1];
	}
	return result;
}

function encodeUuidV7DocId(uuid: string): Uint8Array {
	const bytes = parseUuidBytes(uuid);
	let payload = 0n;

	for (let i = 0; i < 6; i += 1) {
		payload = (payload << 8n) | BigInt(bytes[i]);
	}
	payload = (payload << 4n) | BigInt(bytes[6] & 0x0f);
	payload = (payload << 8n) | BigInt(bytes[7]);
	payload = (payload << 6n) | BigInt(bytes[8] & 0x3f);
	for (let i = 9; i < DOC_ID_BYTE_LENGTH; i += 1) {
		payload = (payload << 8n) | BigInt(bytes[i]);
	}

	return bigIntToBytes(UUID_FAMILY_TAG | payload);
}

function decodeUuidV7DocId(packed: Uint8Array): string {
	// Reserved bits 122..126 (packed[0] bits 2..6) must be zero.
	if ((packed[0] & 0x7c) !== 0) {
		throw invalidDocIdError(
			"Invalid packed UUIDv7 document ID",
			ErrorCodes.INVALID_MESSAGE,
		);
	}
	const cacheIndex =
		((packed[14] << 8) | packed[15]) & (DOC_ID_CACHE_LIMIT - 1);
	const cached = uuidDecodeCache[cacheIndex];
	if (cached !== undefined) {
		let matches = true;
		for (let i = 0; i < DOC_ID_BYTE_LENGTH; i += 1) {
			if (packed[i] !== cached.packed[i]) {
				matches = false;
				break;
			}
		}
		if (matches) return cached.id;
	}

	// Inverse of packUuidV7Bytes: the 122-bit payload is packed as
	// [B0..B5 (48b)] [B6&0x0f (4b)] [B7 (8b)] [B8&0x3f (6b)] [B9..B15 (56b)].
	const bytes = new Uint8Array(DOC_ID_BYTE_LENGTH);
	bytes[0] = ((packed[0] & 0x03) << 6) | (packed[1] >> 2);
	bytes[1] = ((packed[1] & 0x03) << 6) | (packed[2] >> 2);
	bytes[2] = ((packed[2] & 0x03) << 6) | (packed[3] >> 2);
	bytes[3] = ((packed[3] & 0x03) << 6) | (packed[4] >> 2);
	bytes[4] = ((packed[4] & 0x03) << 6) | (packed[5] >> 2);
	bytes[5] = ((packed[5] & 0x03) << 6) | (packed[6] >> 2);
	bytes[6] = 0x70 | (((packed[6] & 0x03) << 2) | (packed[7] >> 6));
	bytes[7] = ((packed[7] & 0x3f) << 2) | (packed[8] >> 6);
	bytes[8] = 0x80 | (packed[8] & 0x3f);
	bytes[9] = packed[9];
	bytes[10] = packed[10];
	bytes[11] = packed[11];
	bytes[12] = packed[12];
	bytes[13] = packed[13];
	bytes[14] = packed[14];
	bytes[15] = packed[15];

	const id = formatUuidBytes(bytes);
	// ponytail: direct-mapped cache; use set-associative slots if collisions matter.
	uuidDecodeCache[cacheIndex] = { packed: packed.slice(), id };
	return id;
}

export function isCanonicalUUIDv7(id: string): boolean {
	return UUID_V7_REGEX.test(id);
}

export function isValidShortDocId(id: string): boolean {
	if (id.length === 0 || id.length > SHORT_ID_MAX_LENGTH) return false;
	for (const char of id) {
		if (!shortCharToDigit.has(char)) return false;
	}
	return true;
}

export function packDocId(
	id: string,
	errorCode: string = ErrorCodes.INVALID_MESSAGE,
): Uint8Array {
	if (isCanonicalUUIDv7(id)) {
		return encodeUuidV7DocId(id);
	}
	if (isValidShortDocId(id)) {
		return encodeShortDocId(id);
	}
	throw invalidDocIdError(
		`Invalid document ID "${id}". Expected canonical UUIDv7 or [a-z0-9_-]{1,24}.`,
		errorCode,
	);
}

export function unpackDocId(bytes: Uint8Array): string {
	if (bytes.byteLength !== DOC_ID_BYTE_LENGTH) {
		throw invalidDocIdError(
			`Invalid document ID byte length ${bytes.byteLength}; expected 16.`,
			ErrorCodes.INVALID_MESSAGE,
		);
	}

	if ((bytes[0] & 0x80) !== 0) {
		return decodeUuidV7DocId(bytes);
	}

	const value = bytesToBigInt(bytes);
	const cached = shortDocIdDecodeCache.get(value);
	if (cached !== undefined) return cached;

	const id = decodeShortDocId(value);
	if (shortDocIdDecodeCache.size >= DOC_ID_CACHE_LIMIT) {
		const first = shortDocIdDecodeCache.keys().next().value;
		if (first !== undefined) shortDocIdDecodeCache.delete(first);
	}
	shortDocIdDecodeCache.set(value, id);
	return id;
}

/**
 * Compare document IDs in packed order without allocating packed bytes.
 * Invalid strings sort lexically after both canonical ID families so callers
 * such as materialized-view comparators remain total and non-throwing.
 */
export function compareDocIds(a: string, b: string): number {
	const aFamily = docIdSortFamily(a);
	const bFamily = docIdSortFamily(b);
	if (aFamily !== bFamily) return aFamily - bFamily;
	return a < b ? -1 : a > b ? 1 : 0;
}

function docIdSortFamily(id: string): 0 | 1 | 2 {
	const cached = docIdSortFamilyCache.get(id);
	if (cached !== undefined) return cached;

	const family = isCanonicalUUIDv7(id) ? 1 : isValidShortDocId(id) ? 0 : 2;
	if (docIdSortFamilyCache.size >= DOC_ID_CACHE_LIMIT) {
		const first = docIdSortFamilyCache.keys().next().value;
		if (first !== undefined) docIdSortFamilyCache.delete(first);
	}
	docIdSortFamilyCache.set(id, family);
	return family;
}
