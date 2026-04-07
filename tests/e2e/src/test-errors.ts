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

		console.log("All error reporting tests passed!");
	} catch (err) {
		console.error("Test failed:", err);
		throw err;
	} finally {
		client.close();
	}
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
