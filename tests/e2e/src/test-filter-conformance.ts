import type { JsonValue, SubscriptionHandle } from "@zyncbase/client";
import {
	FILTER_VECTOR_RECORDS,
	FILTER_VECTORS,
} from "../../../sdk/typescript/src/filter_eval.vectors";
import { ZyncBaseClient } from "./client";

const COLLECTION = "vectors";

function sortedIds(rows: JsonValue[]): string[] {
	return (rows as Record<string, JsonValue>[])
		.map((row) => row.id as string)
		.sort();
}

function mismatch(
	label: string,
	actual: string[],
	expected: string[],
): string | null {
	const want = [...expected].sort();
	return JSON.stringify(actual) === JSON.stringify(want)
		? null
		: `${label}: expected [${want.join(", ")}], got [${actual.join(", ")}]`;
}

/**
 * Runs the SDK filter vectors against the server's two matching paths:
 * deltas (in-memory) for views subscribed before the writes, and snapshots
 * (SQL) for queries issued after them.
 */
export async function run(port: number): Promise<void> {
	const client = new ZyncBaseClient(`ws://127.0.0.1:${port}`);
	const handles: SubscriptionHandle[] = [];
	try {
		await client.connect();
		for (const vector of FILTER_VECTORS) {
			handles.push(
				await client.store.subscribe(
					COLLECTION,
					{ where: vector.where },
					() => {},
				),
			);
		}
		for (const { id, ...value } of FILTER_VECTOR_RECORDS) {
			await client.store.set([COLLECTION, id], value, { optimistic: false });
		}

		const failures: string[] = [];
		for (const [i, vector] of FILTER_VECTORS.entries()) {
			const deltas = sortedIds(handles[i].getSnapshot());
			const snapshot = sortedIds(
				await client.store.query(COLLECTION, { where: vector.where }),
			);
			for (const failure of [
				mismatch(`${vector.name} (deltas)`, deltas, vector.expected),
				mismatch(`${vector.name} (snapshot)`, snapshot, vector.expected),
			]) {
				if (failure) failures.push(failure);
			}
		}
		if (failures.length > 0) {
			throw new Error(`Filter conformance failed:\n${failures.join("\n")}`);
		}
		console.log(
			`E2E filter conformance passed (${FILTER_VECTORS.length} vectors).`,
		);
	} finally {
		await Promise.all(handles.map((handle) => handle.unsubscribe()));
		client.close();
	}
}
