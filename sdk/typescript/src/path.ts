// Path Normalizer

import { ErrorCodes, ZyncBaseError } from "./errors";
import type { JsonValue } from "./types.js";

export type Path = string | string[];

/**
 * Join path segments with "__" to form a flattened field key.
 * This is the single authority for the "__" delimiter in the entire codebase.
 */
export function joinFieldPath(...segments: string[]): string {
	return segments.join("__");
}

/**
 * Split a flattened field key on "__" back into path segments.
 */
export function splitFieldPath(flat: string): string[] {
	return flat.split("__");
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

/**
 * Recursively flatten a nested object using `__` as the key separator.
 * Arrays are stored as-is (not flattened).
 *
 * Example:
 *   flatten({ a: { b: 1, c: 2 } }) → { "a__b": 1, "a__c": 2 }
 */
export function flatten(
	obj: Record<string, JsonValue>,
	prefix = "",
): Record<string, JsonValue> {
	const result: Record<string, JsonValue> = {};
	for (const key of Object.keys(obj)) {
		const fullKey = prefix ? joinFieldPath(prefix, key) : key;
		const value = obj[key];
		if (value !== null && typeof value === "object" && !Array.isArray(value)) {
			const nested = flatten(value as Record<string, JsonValue>, fullKey);
			for (const nestedKey of Object.keys(nested)) {
				result[nestedKey] = nested[nestedKey];
			}
		} else {
			result[fullKey] = value;
		}
	}
	return result;
}

/**
 * Reconstruct a nested object from `__`-separated flat keys.
 *
 * Example:
 *   unflatten({ "a__b": 1, "a__c": 2 }) → { a: { b: 1, c: 2 } }
 */
export function unflatten(
	flat: Record<string, JsonValue>,
): Record<string, JsonValue> {
	const result: Record<string, JsonValue> = {};
	for (const key of Object.keys(flat)) {
		setDeepProperty(result, splitFieldPath(key), flat[key]);
	}
	return result;
}

function setDeepProperty(
	obj: Record<string, JsonValue>,
	parts: string[],
	value: JsonValue,
): void {
	let current = obj;
	for (let i = 0; i < parts.length; i++) {
		const part = parts[i];
		if (i === parts.length - 1) {
			current[part] = value;
		} else {
			if (
				current[part] === undefined ||
				typeof current[part] !== "object" ||
				Array.isArray(current[part])
			) {
				current[part] = {};
			}
			current = current[part] as Record<string, JsonValue>;
		}
	}
}
