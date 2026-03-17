import { ZyncBaseClient } from "./client";

async function main() {
  const mode = process.argv[2]; // "set" or "get"
  const client = new ZyncBaseClient("ws://localhost:3000");

  try {
    await client.connect();
    const namespace = "public";
    const path = ["persistence", "test"];

    if (mode === "set") {
      console.log("Setting persistence record...");
      await client.set(namespace, path, { status: "persisted", timestamp: Date.now() });
      console.log("Record set.");
    } else {
      console.log("Verifying persistence record...");
      const data = await client.get(namespace, path);
      console.log("Retrieved data:", data);
      if (data?.status === "persisted") {
        console.log("Persistence verified.");
      } else {
        throw new Error("Persistence verification failed - record not found or incorrect.");
      }
    }
  } catch (err) {
    console.error("Test failed:", err);
    process.exit(1);
  } finally {
    client.close();
  }
}

main();
