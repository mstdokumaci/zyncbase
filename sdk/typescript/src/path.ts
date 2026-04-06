// Path Normalizer

import { ErrorCodes, ZyncBaseError } from "./errors";

export type Path = string | string[];

/**
 * Encode a normalized path for the wire protocol.
 *
 * The server expects paths as:
 *   depth 1: ["collection"]
 *   depth 2: ["collection", "docId"]
 *   depth 3+: ["collection", "docId", "field__nested__deep"]
 *
 * Segments at index 2+ are joined with "__" into a single flat field key.
 * Single underscores are escaped as "\x00" before joining to avoid ambiguity
 * when a segment ends or starts with "_".
 *
 * Examples:
 *   ["users", "u1"]                    → ["users", "u1"]
 *   ["users", "u1", "name"]            → ["users", "u1", "name"]
 *   ["users", "u1", "address", "city"] → ["users", "u1", "address__city"]
 */
export function encodeWirePath(segments: string[]): string[] {
	if (segments.length <= 2) return segments;
	// Join nested segments with "__" to match server's flattened schema columns.
	const fieldPath = segments.slice(2).join("__");
	return [segments[0], segments[1], fieldPath];
}

/**
 * Decode a wire-format path back to a normalized path.
 *
 * Splits the field segment (index 2) on "__" to restore nested segments.
 */
export function decodeWirePath(wirePath: string[]): string[] {
	if (wirePath.length <= 2) return wirePath;
	const parts = wirePath[2].split("__");
	return [wirePath[0], wirePath[1], ...parts];
}

export function normalizePath(path: Path): string[] {
	const segments = typeof path === "string" ? path.split(".") : path;

	if (segments.length === 0) {
		throw new ZyncBaseError("Path must not be empty", {
			code: ErrorCodes.INVALID_PATH,
			category: "client",
			retryable: false,
		});
	}

	for (const segment of segments) {
		if (segment.length === 0) {
			const detail = typeof path === "string" ? `: "${path}"` : "";
			throw new ZyncBaseError(`Path contains empty segment${detail}`, {
				code: ErrorCodes.INVALID_PATH,
				category: "client",
				retryable: false,
			});
		}
	}
	return segments;
}
