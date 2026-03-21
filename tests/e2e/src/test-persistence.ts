import { ZyncBaseClient } from "./client";
import * as fs from "fs";
import * as path_pkg from "path";

async function main() {
  const mode = process.argv[2]; // "set" or "get"
  const client = new ZyncBaseClient("ws://localhost:3000");
  const timestampFile = path_pkg.join(process.cwd(), "test-artifacts", "persistence_timestamp.txt");

  try {
    await client.connect();
    const namespace = "public";
    const path = ["persistence", "test"];

    if (mode === "set") {
      const timestamp = Date.now();
      console.log(`Setting persistence record with timestamp: ${timestamp}...`);
      await client.set(namespace, path, { status: "persisted", timestamp });
      
      // Store timestamp for verification in "get" phase
      fs.writeFileSync(timestampFile, timestamp.toString());
      console.log("Record set and timestamp stored.");
    } else {
      console.log("Verifying persistence record...");
      
      if (!fs.existsSync(timestampFile)) {
        throw new Error("Timestamp file not found from 'set' phase.");
      }
      const expectedTimestamp = parseInt(fs.readFileSync(timestampFile, "utf-8"), 10);
      
      const data = await client.get(namespace, path);
      console.log("Retrieved data:", data);
      
      if (data?.status === "persisted" && data?.timestamp === expectedTimestamp) {
        console.log("Persistence verified with exact timestamp match.");
      } else {
        throw new Error(`Persistence verification failed. Expected timestamp ${expectedTimestamp}, got ${data?.timestamp}`);
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
