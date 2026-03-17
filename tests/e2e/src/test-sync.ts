import { ZyncBaseClient } from "./client";

async function main() {
  const clientA = new ZyncBaseClient("ws://127.0.0.1:3000");
  const clientB = new ZyncBaseClient("ws://127.0.0.1:3000");

  try {
    console.log("Connecting clients...");
    await Promise.all([clientA.connect(), clientB.connect()]);
    console.log("Clients connected.");

    const namespace = "public";

    // 1. Client A sets task 1
    console.log("Client A setting task 1...");
    await clientA.set(namespace, ["tasks", "1"], { title: "A's Task" });

    // 2. Client B gets task 1 and verifies
    console.log("Client B getting task 1...");
    const task1 = await clientB.get(namespace, ["tasks", "1"]);
    console.log("Client B received task 1:", task1);
    if (task1?.title !== "A's Task") throw new Error("Sync failed for task 1");

    // 3. Client B sets task 2
    console.log("Client B setting task 2...");
    await clientB.set(namespace, ["tasks", "2"], { title: "B's Task" });

    // 4. Client A gets task 2 and verifies
    console.log("Client A getting task 2...");
    const task2 = await clientA.get(namespace, ["tasks", "2"]);
    console.log("Client A received task 2:", task2);
    if (task2?.title !== "B's Task") throw new Error("Sync failed for task 2");

    // 5. Both Client A and Client B get ["tasks"] and verify the collection contains both entries
    console.log("Verifying collection get for Client A...");
    const tasksA = await clientA.get(namespace, ["tasks"]);
    console.log("Client A received tasks collection:", tasksA);
    if (!tasksA || typeof tasksA !== 'object') throw new Error("Collection get failed for Client A");
    if (!tasksA["tasks/1"] || !tasksA["tasks/2"]) throw new Error("Collection missing entries for Client A");

    console.log("Verifying collection get for Client B...");
    const tasksB = await clientB.get(namespace, ["tasks"]);
    console.log("Client B received tasks collection:", tasksB);
    if (!tasksB || typeof tasksB !== 'object') throw new Error("Collection get failed for Client B");
    if (!tasksB["tasks/1"] || !tasksB["tasks/2"]) throw new Error("Collection missing entries for Client B");

    console.log("Collection verification passed.");
    
    console.log("E2E Sync test passed successfully!");
  } catch (err) {
    console.error("Test failed:", err);
    process.exit(1);
  } finally {
    clientA.close();
    clientB.close();
  }
}

main();
