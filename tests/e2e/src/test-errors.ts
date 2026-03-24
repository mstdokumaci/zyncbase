import { ZyncBaseClient } from "./client";

export async function run(port: number = 3000) {
  const client = new ZyncBaseClient(`ws://127.0.0.1:${port}`);

  try {
    console.log("Connecting client...");
    await client.connect();
    console.log("Client connected.");

    const namespace = "public";

    // 1. COLLECTION_NOT_FOUND
    console.log("Testing COLLECTION_NOT_FOUND...");
    try {
      await client.get(namespace, ["non_existent_table", "1"]);
      throw new Error("Expected COLLECTION_NOT_FOUND but got success");
    } catch (err: any) {
      if (err.code !== "COLLECTION_NOT_FOUND") {
        throw new Error(`Expected COLLECTION_NOT_FOUND but got ${err.code}`);
      }
      console.log("COLLECTION_NOT_FOUND verified.");
    }

    // 2. FIELD_NOT_FOUND
    console.log("Testing FIELD_NOT_FOUND...");
    try {
      await client.get(namespace, ["tasks", "1", "non_existent_field"]);
      throw new Error("Expected FIELD_NOT_FOUND but got success");
    } catch (err: any) {
      if (err.code !== "FIELD_NOT_FOUND") {
        throw new Error(`Expected FIELD_NOT_FOUND but got ${err.code}`);
      }
      console.log("FIELD_NOT_FOUND verified.");
    }

    // 3. SCHEMA_VALIDATION_FAILED (Type Mismatch)
    console.log("Testing SCHEMA_VALIDATION_FAILED (Type Mismatch)...");
    try {
      // 'tasks.title' is defined as 'string' in schema-sync.json.
      // We'll try to set it to an integer.
      await client.set(namespace, ["tasks", "1", "title"], 12345);
      throw new Error("Expected SCHEMA_VALIDATION_FAILED but got success");
    } catch (err: any) {
      if (err.code !== "SCHEMA_VALIDATION_FAILED") {
        throw new Error(`Expected SCHEMA_VALIDATION_FAILED but got ${err.code}`);
      }
      console.log("SCHEMA_VALIDATION_FAILED verified.");
    }

    // 4. INVALID_ARRAY_ELEMENT
    console.log("Testing INVALID_ARRAY_ELEMENT...");
    try {
      // 'tasks.tags' is defined as 'array' in schema-sync.json.
      // ZyncBase arrays must only contain literal (primitive) elements.
      // We'll try to set it to an array containing a map (non-literal).
      await client.set(namespace, ["tasks", "1", "tags"], ["tag1", { nested: "map" }]);
      throw new Error("Expected INVALID_ARRAY_ELEMENT but got success");
    } catch (err: any) {
      if (err.code !== "INVALID_ARRAY_ELEMENT") {
        throw new Error(`Expected INVALID_ARRAY_ELEMENT but got ${err.code}`);
      }
      console.log("INVALID_ARRAY_ELEMENT verified.");
    }

    console.log("All error reporting tests passed!");
  } catch (err) {
    console.error("Test failed:", err);
    throw err;
  } finally {
    client.close();
  }
}
