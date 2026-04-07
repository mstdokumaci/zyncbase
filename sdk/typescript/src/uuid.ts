// UUIDv7 generator — RFC 9562
// Uses only Web Platform APIs (crypto.getRandomValues)

let lastMsecs = 0;
let counter = 0;

/**
 * Generates a UUIDv7 string conforming to RFC 9562.
 * - 48-bit millisecond timestamp in bits 0–47
 * - Version nibble `7` at position 14 (bits 48–51)
 * - 12-bit sequence counter in bits 52–63 for sub-millisecond monotonicity
 * - Variant bits `10xx` at position 19 (bits 64–65)
 * - Returns standard 8-4-4-4-12 hyphenated hex string
 */
export function generateUUIDv7(): string {
	const bytes = new Uint8Array(16);
	crypto.getRandomValues(bytes);
	const msecs = Date.now();

	if (msecs < lastMsecs) {
		counter = 0;
	}
	if (msecs === lastMsecs) {
		counter++;
	} else {
		counter = 0;
	}
	lastMsecs = msecs;

	// Encode 48-bit timestamp into bytes 0–5
	bytes[0] = (msecs / 0x10000000000) & 0xff;
	bytes[1] = (msecs / 0x100000000) & 0xff;
	bytes[2] = (msecs / 0x1000000) & 0xff;
	bytes[3] = (msecs / 0x10000) & 0xff;
	bytes[4] = (msecs / 0x100) & 0xff;
	bytes[5] = msecs & 0xff;

	// byte 6: high nibble = version 7, low nibble = high 4 bits of counter
	bytes[6] = 0x70 | ((counter >> 8) & 0x0f);
	// byte 7: low 8 bits of counter
	bytes[7] = counter & 0xff;

	// byte 8: variant bits 10xx
	bytes[8] = (bytes[8] & 0x3f) | 0x80;

	// Format as 8-4-4-4-12 hyphenated hex string
	const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join(
		"",
	);
	return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
