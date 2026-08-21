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
