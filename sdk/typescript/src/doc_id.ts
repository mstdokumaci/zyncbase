import { ErrorCodes, ZyncBaseError } from "./errors.js";

export const DOC_ID_BYTE_LENGTH = 16;
export const SHORT_ID_MAX_LENGTH = 24;
export const SHORT_ID_ALPHABET = "-0123456789_abcdefghijklmnopqrstuvwxyz";

const SHORT_BASE = 39n;
const SHORT_DIGITS = 24;
const UUID_FAMILY_TAG = 1n << 127n;
const UUID_PAYLOAD_MASK = (1n << 122n) - 1n;
const UUID_RESERVED_MASK = ((1n << 127n) - 1n) ^ UUID_PAYLOAD_MASK;
const UUID_V7_REGEX =
	/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

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
	let value = 0n;
	for (const byte of bytes) {
		value = (value << 8n) | BigInt(byte);
	}
	return value;
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

function formatUuidBytes(bytes: Uint8Array): string {
	const hex = Array.from(bytes, (byte) =>
		byte.toString(16).padStart(2, "0"),
	).join("");
	return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function encodeShortDocId(id: string): Uint8Array {
	let value = 0n;
	for (let i = 0; i < SHORT_DIGITS; i += 1) {
		const digit = i < id.length ? shortCharToDigit.get(id[i]) ?? 0 : 0;
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
		throw invalidDocIdError("Invalid packed short document ID", ErrorCodes.INVALID_MESSAGE);
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

function decodeUuidV7DocId(value: bigint): string {
	if ((value & UUID_RESERVED_MASK) !== 0n) {
		throw invalidDocIdError(
			"Invalid packed UUIDv7 document ID",
			ErrorCodes.INVALID_MESSAGE,
		);
	}

	let payload = value & UUID_PAYLOAD_MASK;
	const bytes = new Uint8Array(DOC_ID_BYTE_LENGTH);

	for (let i = DOC_ID_BYTE_LENGTH - 1; i >= 9; i -= 1) {
		bytes[i] = Number(payload & 0xffn);
		payload >>= 8n;
	}
	bytes[8] = 0x80 | Number(payload & 0x3fn);
	payload >>= 6n;
	bytes[7] = Number(payload & 0xffn);
	payload >>= 8n;
	bytes[6] = 0x70 | Number(payload & 0x0fn);
	payload >>= 4n;
	for (let i = 5; i >= 0; i -= 1) {
		bytes[i] = Number(payload & 0xffn);
		payload >>= 8n;
	}

	if (payload !== 0n) {
		throw invalidDocIdError(
			"Invalid packed UUIDv7 payload length",
			ErrorCodes.INVALID_MESSAGE,
		);
	}

	return formatUuidBytes(bytes);
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

	const value = bytesToBigInt(bytes);
	if ((value & UUID_FAMILY_TAG) !== 0n) {
		return decodeUuidV7DocId(value);
	}
	return decodeShortDocId(value);
}
