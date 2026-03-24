import { ZyncBaseClient } from "./client";

export async function run(port: number = 3000) {
  const clientA = new ZyncBaseClient(`ws://127.0.0.1:${port}`);
  const clientB = new ZyncBaseClient(`ws://127.0.0.1:${port}`);

  try {
    console.log("Connecting clients...");
    await Promise.all([clientA.connect(), clientB.connect()]);
    console.log("Clients connected.");

    const namespace = "public";

    // 1. Client A sets task 1 with tags
    console.log("Client A setting task 1...");
    await clientA.set(namespace, ["tasks", "1"], { title: "A's Task", tags: ["urgent", "home"] });

    // 2. Client B gets task 1 and verifies
    console.log("Client B waiting for task 1...");
    const task1 = await clientB.waitFor(namespace, ["tasks", "1"], (val) => {
      return val?.title === "A's Task" && Array.isArray(val.tags) && val.tags.includes("urgent") ? val : null;
    });
    console.log("Client B received task 1:", task1);

    // 3. Client B sets task 2 with tags
    console.log("Client B setting task 2...");
    await clientB.set(namespace, ["tasks", "2"], { title: "B's Task", tags: ["work"] });

    // 4. Client A gets task 2 and verifies
    console.log("Client A waiting for task 2...");
    const task2 = await clientA.waitFor(namespace, ["tasks", "2"], (val) => {
      return val?.title === "B's Task" && Array.isArray(val.tags) && val.tags.includes("work") ? val : null;
    });
    console.log("Client A received task 2:", task2);

    // 5. Verify both clients see the same deterministic state (ignoring dynamic timestamps)
    const getSnapshot = (tasks: any[]) => JSON.stringify(tasks.map(t => ({ id: t.id, title: t.title, tags: t.tags })).sort((a, b) => a.id.localeCompare(b.id)));
    const expected = JSON.stringify([
      { id: "1", title: "A's Task", tags: ["urgent", "home"] },
      { id: "2", title: "B's Task", tags: ["work"] }
    ]);

    const tasksA = await clientA.get(namespace, ["tasks"]) as any[];
    if (getSnapshot(tasksA) !== expected) throw new Error(`Client A mismatch. Got: ${getSnapshot(tasksA)}`);

    const tasksB = await clientB.get(namespace, ["tasks"]) as any[];
    if (getSnapshot(tasksB) !== expected) throw new Error(`Client B mismatch. Got: ${getSnapshot(tasksB)}`);

    console.log("Collection verification passed.");

    console.log("E2E Sync test passed successfully!");
  } catch (err) {
    console.error("Test failed:", err);
    throw err;
  } finally {
    clientA.close();
    clientB.close();
  }
}
