import type {
	JsonValue,
	QueryOptions,
	SubscriptionHandle,
} from "@zyncbase/client";
import { ZyncBaseClient } from "./client";

const IDS = ["sort-z", "sort-a", "sort-c", "sort-d", "sort-e"];
const OPTIONS: QueryOptions = {
	where: { tags: { contains: "sort-proof" } },
	orderBy: [{ priority: "desc" }, { "metrics.rank": "asc" }],
};

function recordIds(rows: JsonValue[]): string[] {
	return (rows as Record<string, JsonValue>[]).map((row) => row.id as string);
}

function expectIds(rows: JsonValue[], expected: string[]): void {
	const actual = recordIds(rows);
	if (JSON.stringify(actual) !== JSON.stringify(expected)) {
		throw new Error(
			`Expected sort order ${expected.join(",")}, got ${actual.join(",")}`,
		);
	}
}

async function waitUntil(
	predicate: () => boolean,
	label: string,
): Promise<void> {
	const deadline = Date.now() + 10_000;
	while (!predicate()) {
		if (Date.now() >= deadline)
			throw new Error(`Timed out waiting for ${label}`);
		await new Promise((resolve) => setTimeout(resolve, 10));
	}
}

export async function run(port: number = 3000): Promise<void> {
	const client = new ZyncBaseClient(`ws://127.0.0.1:${port}`);
	let limited: SubscriptionHandle | null = null;
	let live: SubscriptionHandle | null = null;

	try {
		await client.connect();
		await Promise.all([
			client.store.set(
				["items", IDS[0]],
				{ priority: 2, metrics: { rank: 1 }, tags: ["sort-proof"] },
				{ confirm: "committed" },
			),
			client.store.set(
				["items", IDS[1]],
				{ priority: 2, metrics: { rank: 1 }, tags: ["sort-proof"] },
				{ confirm: "committed" },
			),
			client.store.set(
				["items", IDS[2]],
				{ priority: 2, metrics: { rank: 2 }, tags: ["sort-proof"] },
				{ confirm: "committed" },
			),
			client.store.set(
				["items", IDS[3]],
				{ priority: 1, metrics: { rank: 0 }, tags: ["sort-proof"] },
				{ confirm: "committed" },
			),
			client.store.set(
				["items", IDS[4]],
				{ priority: 1, tags: ["sort-proof"] },
				{ confirm: "committed" },
			),
		]);

		const first = await client.store.query("items", { ...OPTIONS, limit: 2 });
		expectIds(first, [IDS[0], IDS[1]]);
		if (first.nextCursor === null)
			throw new Error("First sort page has no cursor");
		const second = await client.store.query("items", {
			...OPTIONS,
			limit: 2,
			after: first.nextCursor,
		});
		expectIds(second, [IDS[2], IDS[3]]);
		if (second.nextCursor === null)
			throw new Error("Second sort page has no cursor");
		const third = await client.store.query("items", {
			...OPTIONS,
			limit: 2,
			after: second.nextCursor,
		});
		expectIds(third, [IDS[4]]);
		if (third.nextCursor !== null)
			throw new Error("Final sort page unexpectedly has a cursor");

		let limitedRows: JsonValue[] = [];
		limited = client.store.subscribe(
			"items",
			{ ...OPTIONS, limit: 2 },
			(rows) => {
				limitedRows = rows;
			},
		);
		await waitUntil(() => limitedRows.length === 2, "limited sort snapshot");
		expectIds(limitedRows, [IDS[0], IDS[1]]);
		await limited.loadMore();
		await waitUntil(() => limitedRows.length === 4, "first sorted loadMore");
		expectIds(limitedRows, [IDS[0], IDS[1], IDS[2], IDS[3]]);
		await limited.loadMore();
		await waitUntil(() => limitedRows.length === 5, "second sorted loadMore");
		expectIds(limitedRows, IDS);
		limited.unsubscribe();
		limited = null;

		let liveRows: JsonValue[] = [];
		live = client.store.subscribe("items", OPTIONS, (rows) => {
			liveRows = rows;
		});
		await waitUntil(() => liveRows.length === 5, "full sorted subscription");
		expectIds(liveRows, IDS);

		await client.store.set(
			["items", IDS[2]],
			{ priority: 3, metrics: { rank: 2 }, tags: ["sort-proof"] },
			{ confirm: "committed" },
		);
		await waitUntil(
			() => recordIds(liveRows)[0] === IDS[2],
			"live sort-field reorder",
		);
		expectIds(liveRows, [IDS[2], IDS[0], IDS[1], IDS[3], IDS[4]]);

		console.log("E2E multi-field sorting and pagination passed.");
	} finally {
		limited?.unsubscribe();
		live?.unsubscribe();
		client.close();
	}
}
