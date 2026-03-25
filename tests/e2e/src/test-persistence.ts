import { ZyncBaseClient } from "./client";
import * as fs from "fs";
import * as path_pkg from "path";

export async function run(mode: "set" | "get", port: number = 3000, artifactDir: string = "test-artifacts/e2e") {
  const client = new ZyncBaseClient(`ws://localhost:${port}`);
  const timestampFile = path_pkg.join(process.cwd(), artifactDir, "persistence_timestamp.txt");

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
    throw err;
  } finally {
    client.close();
  }
}
