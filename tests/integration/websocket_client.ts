const inputArg = process.argv[2] || "9001";
const url = inputArg.includes("://") ? inputArg : `ws://127.0.0.1:${inputArg}/`;
const healthUrl = url.replace(/^ws/, "http");

console.log(`=== Comprehensive WebSocket Test (URL: ${url}) ===`);

async function runTest() {
  console.log("Step 1: Verifying HTTP health check...");
  try {
    const response = await fetch(healthUrl);
    const text = await response.text();
    if (text === "OK") {
        console.log("✓ HTTP health check passed");
    } else {
        throw new Error(`HTTP health check failed: expected "OK", got "${text}"`);
    }
  } catch (err) {
    throw new Error(`HTTP health check failed: ${err.message}`);
  }

  console.log("Step 2: Verifying WebSocket callbacks...");
  return new Promise<void>((resolve, reject) => {
    let ws: WebSocket;
    const timeout = setTimeout(() => {
        if (ws) ws.close();
        reject(new Error("Connection timeout after 5s"));
    }, 5000);

    try {
        ws = new WebSocket(url);
        
        ws.onopen = () => {
          console.log("✓ onopen called");
          ws.send("Hello from client");
        };

        ws.onmessage = (event) => {
          console.log(`✓ onmessage called: ${event.data}`);
          if (event.data === "Hello from client") {
            console.log("✓ message echoed correctly");
            ws.close();
            clearTimeout(timeout);
            resolve();
          }
        };

        ws.onclose = (event) => {
          console.log(`✓ onclose called (code: ${event.code})`);
          clearTimeout(timeout);
          if (event.code === 1000 || event.code === 1005) {
            resolve();
          } else {
            reject(new Error(`Closed with unexpected code: ${event.code}`));
          }
        };

        ws.onerror = (error) => {
          console.error("✗ onerror called");
          clearTimeout(timeout);
          reject(error);
        };
    } catch (err) {
        clearTimeout(timeout);
        reject(err);
    }
  });
}

runTest()
  .then(() => {
    console.log("\n=== Test Summary ===");
    console.log("Tests passed: 1");
    process.exit(0);
  })
  .catch((err) => {
    console.error("\n=== Test Summary ===");
    console.error(`✗ Comprehensive test failed: ${err.message || err}`);
    process.exit(1);
  });
