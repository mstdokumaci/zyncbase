import { ZyncBaseClient } from "./client";

export async function run(port: number = 3000) {
	const client = new ZyncBaseClient(`ws://127.0.0.1:${port}`);

	try {
		console.log("Connecting client...");
		await client.connect();
		console.log("Client connected.");

		const namespace = "public";

		await testCollectionNotFound(client, namespace);
		await testFieldNotFound(client, namespace);
		await testSchemaValidationFailed(client, namespace);
		await testInvalidArrayElement(client, namespace);
		await testForeignKeys(client, namespace);
		await testUniqueConstraints(client);

		console.log("All error reporting tests passed!");
	} catch (err) {
		console.error("Test failed:", err);
		throw err;
	} finally {
		client.close();
	}
}

async function testForeignKeys(client: ZyncBaseClient, ns: string) {
	console.log("Testing foreign-key enforcement and delete actions...");
	await client.setNamespace(ns);
	const committed = { confirm: "committed" } as const;

	let orphanError: { code?: string } | undefined;
	try {
		await client.store.set(
			["fk_restrict_children", "orphan"],
			{ parent_id: "missing" },
			committed,
		);
	} catch (err: unknown) {
		orphanError = err as { code?: string };
	}
	if (orphanError === undefined) {
		throw new Error("Expected orphan write to fail");
	}
	if (orphanError.code !== "SCHEMA_VALIDATION_FAILED") {
		throw new Error(
			`Expected SCHEMA_VALIDATION_FAILED but got ${orphanError.code}`,
		);
	}

	await client.store.set(["fk_parents", "restricted"], {}, committed);
	await client.store.set(
		["fk_restrict_children", "restricted-child"],
		{ parent_id: "restricted" },
		committed,
	);
	let restrictedDeleteError: { code?: string } | undefined;
	try {
		await client.store.remove(["fk_parents", "restricted"], committed);
	} catch (err: unknown) {
		restrictedDeleteError = err as { code?: string };
	}
	if (restrictedDeleteError === undefined) {
		throw new Error("Expected restricted parent delete to fail");
	}
	if (restrictedDeleteError.code !== "SCHEMA_VALIDATION_FAILED") {
		throw new Error(
			`Expected SCHEMA_VALIDATION_FAILED but got ${restrictedDeleteError.code}`,
		);
	}

	await client.store.set(["fk_parents", "actions"], {}, committed);
	await client.store.set(
		["fk_cascade_children", "cascade-child"],
		{ parent_id: "actions" },
		committed,
	);
	await client.store.set(
		["fk_nullable_children", "nullable-child"],
		{ parent_id: "actions" },
		committed,
	);
	await client.store.remove(["fk_parents", "actions"], committed);

	const cascaded = await client.store.get([
		"fk_cascade_children",
		"cascade-child",
	]);
	if (cascaded != null) throw new Error("Cascade child still exists");
	const nullable = (await client.store.get([
		"fk_nullable_children",
		"nullable-child",
	])) as { parent_id?: string | null } | null | undefined;
	if (nullable == null) {
		throw new Error("Nullable child was deleted instead of set to null");
	}
	if (nullable.parent_id != null) {
		throw new Error(`Expected parent_id=null, got ${nullable.parent_id}`);
	}

	console.log("Foreign-key enforcement verified.");
}

async function testUniqueConstraints(client: ZyncBaseClient) {
	console.log("Testing user-defined unique constraints...");
	await client.setNamespace("public");
	const committed = { confirm: "committed" } as const;

	// Single-field constraint: same slug in one namespace rejects.
	await client.store.set(
		["unique_projects", "proj-1"],
		{
			slug: "e2e-taken",
			provider: "github",
			externalId: "1001",
			profile: { handle: "handle-one" },
		},
		committed,
	);

	let duplicateError: { code?: string } | undefined;
	try {
		await client.store.set(
			["unique_projects", "proj-2"],
			{
				slug: "e2e-taken",
				provider: "gitlab",
				externalId: "1002",
			},
			committed,
		);
	} catch (err: unknown) {
		duplicateError = err as { code?: string };
	}
	if (duplicateError === undefined) {
		throw new Error("Expected duplicate slug write to fail");
	}
	if (duplicateError.code !== "UNIQUE_CONSTRAINT_VIOLATED") {
		throw new Error(
			`Expected UNIQUE_CONSTRAINT_VIOLATED but got ${duplicateError.code}`,
		);
	}

	// Same key in another namespace commits.
	await client.setNamespace("unique-alt");
	await client.store.set(
		["unique_projects", "proj-3"],
		{
			slug: "e2e-taken",
			provider: "github",
			externalId: "1001",
		},
		committed,
	);
	await client.setNamespace("public");

	// Compound collision rejects.
	let compoundError: { code?: string } | undefined;
	try {
		await client.store.set(
			["unique_projects", "proj-4"],
			{
				slug: "other-slug",
				provider: "github",
				externalId: "1001",
			},
			committed,
		);
	} catch (err: unknown) {
		compoundError = err as { code?: string };
	}
	if (
		compoundError === undefined ||
		compoundError.code !== "UNIQUE_CONSTRAINT_VIOLATED"
	) {
		throw new Error(
			`Expected compound collision to reject with UNIQUE_CONSTRAINT_VIOLATED, got ${compoundError?.code}`,
		);
	}

	// Update into another row's key rejects.
	await client.store.set(
		["unique_projects", "upd-a"],
		{ slug: "upd-a", provider: "u", externalId: "ua" },
		committed,
	);
	await client.store.set(
		["unique_projects", "upd-b"],
		{ slug: "upd-b", provider: "u", externalId: "ub" },
		committed,
	);

	let updateCollisionError: { code?: string } | undefined;
	try {
		await client.store.set(
			["unique_projects", "upd-a", "slug"],
			"upd-b",
			committed,
		);
	} catch (err: unknown) {
		updateCollisionError = err as { code?: string };
	}
	if (updateCollisionError === undefined) {
		throw new Error("Expected update into another row's unique key to fail");
	}
	if (updateCollisionError.code !== "UNIQUE_CONSTRAINT_VIOLATED") {
		throw new Error(
			`Expected UNIQUE_CONSTRAINT_VIOLATED but got ${updateCollisionError.code}`,
		);
	}

	// Two omitted optional values commit, proving SQLite null semantics.
	await client.store.set(
		["unique_projects", "null-1"],
		{ slug: "null-a", provider: "gh", externalId: "n1" },
		committed,
	);
	await client.store.set(
		["unique_projects", "null-2"],
		{ slug: "null-b", provider: "gh", externalId: "n2" },
		committed,
	);
	const nullTwo = await client.store.get(["unique_projects", "null-2"]);
	if (nullTwo == null)
		throw new Error("Optional-constrained doc did not commit");

	// Omitting the nested optional unique field twice is fine.
	await client.store.set(
		["unique_projects", "no-handle-1"],
		{ slug: "nh-1", provider: "x", externalId: "y1" },
		committed,
	);
	await client.store.set(
		["unique_projects", "no-handle-2"],
		{ slug: "nh-2", provider: "x", externalId: "y2" },
		committed,
	);

	console.log("Unique constraint enforcement verified.");
}

async function testCollectionNotFound(client: ZyncBaseClient, ns: string) {
	console.log("Testing COLLECTION_NOT_FOUND...");
	try {
		await client.get(ns, ["non_existent_table", "1"]);
		throw new Error("Expected COLLECTION_NOT_FOUND but got success");
	} catch (err: unknown) {
		const error = err as { code: string };
		if (error.code !== "COLLECTION_NOT_FOUND") {
			throw new Error(`Expected COLLECTION_NOT_FOUND but got ${error.code}`);
		}
		console.log("COLLECTION_NOT_FOUND verified.");
	}
}

async function testFieldNotFound(client: ZyncBaseClient, ns: string) {
	console.log("Testing FIELD_NOT_FOUND...");
	try {
		await client.get(ns, ["tasks", "1", "non_existent_field"]);
		throw new Error("Expected FIELD_NOT_FOUND but got success");
	} catch (err: unknown) {
		const error = err as { code: string };
		if (error.code !== "FIELD_NOT_FOUND") {
			throw new Error(`Expected FIELD_NOT_FOUND but got ${error.code}`);
		}
		console.log("FIELD_NOT_FOUND verified.");
	}
}

async function testSchemaValidationFailed(client: ZyncBaseClient, ns: string) {
	console.log("Testing SCHEMA_VALIDATION_FAILED (Type Mismatch)...");
	try {
		await client.set(ns, ["tasks", "1", "title"], 12345);
		throw new Error("Expected SCHEMA_VALIDATION_FAILED but got success");
	} catch (err: unknown) {
		const error = err as { code: string };
		if (error.code !== "SCHEMA_VALIDATION_FAILED") {
			throw new Error(
				`Expected SCHEMA_VALIDATION_FAILED but got ${error.code}`,
			);
		}
		console.log("SCHEMA_VALIDATION_FAILED verified.");
	}
}

async function testInvalidArrayElement(client: ZyncBaseClient, ns: string) {
	console.log("Testing INVALID_ARRAY_ELEMENT...");
	try {
		await client.set(ns, ["tasks", "1", "tags"], ["tag1", { nested: "map" }]);
		throw new Error("Expected INVALID_ARRAY_ELEMENT but got success");
	} catch (err: unknown) {
		const error = err as { code: string };
		if (error.code !== "INVALID_ARRAY_ELEMENT") {
			throw new Error(`Expected INVALID_ARRAY_ELEMENT but got ${error.code}`);
		}
		console.log("INVALID_ARRAY_ELEMENT verified.");
	}
}
