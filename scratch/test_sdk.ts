import { ZyncBaseClient } from "../sdk/typescript/src/client";

async function main() {
    const client = new ZyncBaseClient({ url: "ws://127.0.0.1:3000", debug: true });
    console.log("Client created");
    try {
        await client.connect();
        console.log("Connected");
    } catch (err) {
        console.error("Connection failed", err);
    }
    client.disconnect();
}

main();
