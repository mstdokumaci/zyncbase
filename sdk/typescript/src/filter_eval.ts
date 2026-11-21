import { getDeepProperty, splitFieldPath } from "./path.js";
import { OP_CODES, type WireCondition } from "./store_wire.js";
import type { JsonValue } from "./types.js";
import { compareScalars, scalarsEqual, sortedSet } from "./value_order.js";

/** Whether a record belongs in a view; the server's delta matching, client side. */
export type RecordMatcher = (record: JsonValue) => boolean;

type Condition = WireCondition | [string, number, JsonValue?];

/** A wire `where`, as `encodeQueryOptions` builds it. */
export interface WireWhere {
	conditions?: readonly Condition[];
	orConditions?: readonly Condition[];
}

type ValueTest = (value: JsonValue) => boolean;

const ORDERINGS: Record<number, (order: number) => boolean> = {
	[OP_CODES.gt]: (order) => order > 0,
	[OP_CODES.lt]: (order) => order < 0,
	[OP_CODES.gte]: (order) => order >= 0,
	[OP_CODES.lte]: (order) => order <= 0,
};

/**
 * Compiles a wire `where` into a matcher: every condition holds, and when
 * `orConditions` is present at least one of them holds. `isDocIdField`
 * reports whether a flat field name holds document ids.
 */
export function compileWhere(
	where: WireWhere,
	isDocIdField: (field: string) => boolean,
): RecordMatcher {
	const all = (where.conditions ?? []).map((c) =>
		compileCondition(c, isDocIdField),
	);
	const any = (where.orConditions ?? []).map((c) =>
		compileCondition(c, isDocIdField),
	);
	return (record) =>
		all.every((matches) => matches(record)) &&
		(any.length === 0 || any.some((matches) => matches(record)));
}

function compileCondition(
	[field, op, operand = null]: Condition,
	isDocIdField: (field: string) => boolean,
): RecordMatcher {
	const parts = splitFieldPath(field);
	const test = compileTest(op, operand, isDocIdField(field));
	return (record) => test(getDeepProperty(record, parts) ?? null);
}

function compileTest(
	op: number,
	operand: JsonValue,
	docId: boolean,
): ValueTest {
	switch (op) {
		case OP_CODES.isNull:
			return (value) => value === null;
		case OP_CODES.isNotNull:
			return (value) => value !== null;
		case OP_CODES.eq:
			return compileEquality(operand, docId, false);
		case OP_CODES.ne:
			return compileEquality(operand, docId, true);
		case OP_CODES.in:
			return compileMembership(operand as JsonValue[], false);
		case OP_CODES.notIn:
			return compileMembership(operand as JsonValue[], true);
		case OP_CODES.contains:
			return compileContains(operand);
		case OP_CODES.startsWith:
			return compileText(operand, (value, needle) => value.startsWith(needle));
		case OP_CODES.endsWith:
			return compileText(operand, (value, needle) => value.endsWith(needle));
		default:
			return compileOrdering(ORDERINGS[op], operand, docId);
	}
}

/** Null fails both `eq` and `ne`; arrays compare as sorted sets. */
function compileEquality(
	operand: JsonValue,
	docId: boolean,
	negate: boolean,
): ValueTest {
	const expected = snapshotBinary(operand);
	const equals: ValueTest = Array.isArray(expected)
		? setEquals(sortedSet(expected, docId), docId)
		: (value) => scalarsEqual(value, expected);
	return (value) => value !== null && equals(value) !== negate;
}

/** Snapshot bytes so later caller mutations cannot change a compiled predicate. */
function snapshotBinary(value: JsonValue): JsonValue {
	if (value instanceof Uint8Array) return value.slice();
	if (Array.isArray(value)) return value.map(snapshotBinary);
	return value;
}

function setEquals(expected: JsonValue[], docId: boolean): ValueTest {
	return (value) => {
		if (!Array.isArray(value)) return false;
		const actual = sortedSet(value, docId);
		return (
			actual.length === expected.length &&
			actual.every((item, i) => scalarsEqual(item, expected[i]))
		);
	};
}

/** `in []` matches nothing and `notIn []` everything, null included; otherwise null fails both. */
function compileMembership(members: JsonValue[], negate: boolean): ValueTest {
	if (members.length === 0) return () => negate;
	const set = new Set(members);
	return (value) => value !== null && set.has(value) !== negate;
}

/** Exact element membership on arrays; ASCII case-insensitive substring on text. */
function compileContains(operand: JsonValue): ValueTest {
	const text = compileText(operand, (value, needle) => value.includes(needle));
	return (value) =>
		Array.isArray(value)
			? value.some((item) => scalarsEqual(item, operand))
			: text(value);
}

function compileText(
	operand: JsonValue,
	matches: (value: string, needle: string) => boolean,
): ValueTest {
	const needle = typeof operand === "string" ? foldAscii(operand) : null;
	return (value) =>
		typeof value === "string" &&
		needle !== null &&
		matches(foldAscii(value), needle);
}

function compileOrdering(
	accepts: (order: number) => boolean,
	operand: JsonValue,
	docId: boolean,
): ValueTest {
	return (value) =>
		value !== null &&
		typeof value === typeof operand &&
		accepts(compareScalars(value, operand, docId));
}

/** Lowercases A-Z only, like the server's ASCII case-insensitive matching. */
function foldAscii(value: string): string {
	return value.replace(/[A-Z]/g, (char) => char.toLowerCase());
}
