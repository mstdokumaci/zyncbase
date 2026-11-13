import type { JsonValue } from "@zyncbase/client";
import { ZyncBaseClient } from "./client";

const committed = { confirm: "committed" } as const;

function balanceOf(value: JsonValue | null | undefined): number {
	if (value === null || typeof value !== "object" || Array.isArray(value)) {
		throw new Error(`Expected an account record, got ${JSON.stringify(value)}`);
	}
	const balance = (value as Record<string, JsonValue>).balance;
	if (typeof balance !== "number") {
		throw new Error(`Expected numeric balance, got ${JSON.stringify(balance)}`);
	}
	return balance;
}

function errorCode(err: unknown): string | undefined {
	return (err as { code?: string }).code;
}

async function expectCode(
	label: string,
	expected: string,
	fn: () => Promise<unknown>,
): Promise<void> {
	let code: string | undefined;
	try {
		await fn();
	} catch (err) {
		code = errorCode(err);
	}
	if (code !== expected) {
		throw new Error(`${label}: expected ${expected}, got ${code}`);
	}
}

async function readBalance(
	client: ZyncBaseClient,
	id: string,
): Promise<number> {
	return balanceOf(await client.store.get(["accounts", id]));
}

async function testConcurrentIncrements(client: ZyncBaseClient): Promise<void> {
	await client.store.set(["accounts", "acct-1"], { balance: 50 }, committed);
	await Promise.all(
		Array.from({ length: 50 }, () =>
			client.store.increment(["accounts", "acct-1", "balance"], -1),
		),
	);
	const balance = await readBalance(client, "acct-1");
	if (balance !== 0) {
		throw new Error(`Expected balance 0, got ${balance}`);
	}
}

async function testConditionalIncrements(
	client: ZyncBaseClient,
): Promise<void> {
	await client.store.set(["accounts", "acct-2"], { balance: 5 }, committed);
	const results = await Promise.allSettled(
		Array.from({ length: 10 }, () =>
			client.store.increment(["accounts", "acct-2", "balance"], -1, {
				if: { balance: { gte: 1 } },
			}),
		),
	);
	const succeeded = results.filter((r) => r.status === "fulfilled").length;
	const failed = results.filter((r) => r.status === "rejected");
	if (succeeded !== 5 || failed.length !== 5) {
		throw new Error(
			`Expected 5 successes and 5 failures, got ${succeeded} and ${failed.length}`,
		);
	}
	for (const failure of failed) {
		if (errorCode(failure.reason) !== "PRECONDITION_FAILED") {
			throw new Error(
				`Expected PRECONDITION_FAILED, got ${errorCode(failure.reason)}`,
			);
		}
	}
	const balance = await readBalance(client, "acct-2");
	if (balance !== 0) {
		throw new Error(`Expected conditional balance 0, got ${balance}`);
	}
}

async function testConditionalSet(client: ZyncBaseClient): Promise<void> {
	await client.store.set(["accounts", "acct-3"], { balance: 10 }, committed);
	await client.store.set(["accounts", "acct-3", "balance"], 7, {
		confirm: "committed",
		if: { balance: { eq: 10 } },
	});
	if ((await readBalance(client, "acct-3")) !== 7) {
		throw new Error("Conditional set did not apply");
	}
	await expectCode("conditional set mismatch", "PRECONDITION_FAILED", () =>
		client.store.set(["accounts", "acct-3", "balance"], 3, {
			confirm: "committed",
			if: { balance: { eq: 10 } },
		}),
	);
	if ((await readBalance(client, "acct-3")) !== 7) {
		throw new Error("Failed conditional set changed the row");
	}
}

async function testMissingRows(client: ZyncBaseClient): Promise<void> {
	await expectCode(
		"conditional set on missing row",
		"PRECONDITION_FAILED",
		() =>
			client.store.set(
				["accounts", "acct-missing"],
				{ balance: 1 },
				{
					confirm: "committed",
					if: { balance: { eq: 0 } },
				},
			),
	);
	if ((await client.store.get(["accounts", "acct-missing"])) !== null) {
		throw new Error("Conditional set unexpectedly created a missing document");
	}
	await expectCode(
		"conditional remove on missing row",
		"PRECONDITION_FAILED",
		() =>
			client.store.remove(["accounts", "acct-missing"], {
				confirm: "committed",
				if: { balance: { eq: 0 } },
			}),
	);
}

async function testBatchTransfer(client: ZyncBaseClient): Promise<void> {
	await client.store.set(["accounts", "acct-4"], { balance: 100 }, committed);
	await client.store.set(["accounts", "acct-5"], { balance: 0 }, committed);
	await client.store.batch(
		[
			{
				op: "increment",
				path: ["accounts", "acct-4", "balance"],
				by: -40,
				if: { balance: { gte: 40 } },
			},
			{ op: "increment", path: ["accounts", "acct-5", "balance"], by: 40 },
		],
		committed,
	);
	if ((await readBalance(client, "acct-4")) !== 60) {
		throw new Error("Expected source balance 60 after transfer");
	}
	if ((await readBalance(client, "acct-5")) !== 40) {
		throw new Error("Expected destination balance 40 after transfer");
	}

	await expectCode("failed transfer", "PRECONDITION_FAILED", () =>
		client.store.batch(
			[
				{
					op: "increment",
					path: ["accounts", "acct-4", "balance"],
					by: -1000,
					if: { balance: { gte: 1000 } },
				},
				{ op: "increment", path: ["accounts", "acct-5", "balance"], by: 1 },
			],
			committed,
		),
	);
	if ((await readBalance(client, "acct-4")) !== 60) {
		throw new Error("Failed batch changed source balance");
	}
	if ((await readBalance(client, "acct-5")) !== 40) {
		throw new Error("Failed batch changed destination balance");
	}
}

async function testConfirmation(client: ZyncBaseClient): Promise<void> {
	await expectCode(
		"conditional write without committed",
		"INVALID_MESSAGE",
		() =>
			client.store.set(["accounts", "acct-3", "balance"], 1, {
				if: { balance: { eq: 7 } },
			}),
	);
}

export async function run(port: number = 3000) {
	const client = new ZyncBaseClient(`ws://127.0.0.1:${port}`);
	try {
		console.log("Connecting conditional-write client...");
		await client.connect();
		await client.setNamespace("public");

		await testConcurrentIncrements(client);
		await testConditionalIncrements(client);
		await testConditionalSet(client);
		await testMissingRows(client);
		await testBatchTransfer(client);
		await testConfirmation(client);

		console.log("Conditional write and increment tests passed!");
	} finally {
		client.close();
	}
}
