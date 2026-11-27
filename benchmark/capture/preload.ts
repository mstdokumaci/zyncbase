import * as fs from "node:fs";
import * as path from "node:path";

// Captures WebSocket traffic: one NDJSON file per process, client->server
// frames plus the first server->client frame (SchemaSync).
const captureDir = process.env.ZYNCBASE_COMBO_CAPTURE_DIR;
if (captureDir) {
	fs.mkdirSync(captureDir, { recursive: true });
	const file = path.join(captureDir, `capture-${process.pid}.ndjson`);
	let inboundCaptured = false;

	const record = (dir: "c2s" | "s2c", bytes: Uint8Array) => {
		// Capture runs are not timed. Write immediately so worker teardown cannot
		// lose the final buffered frames (presence/shared phases).
		fs.appendFileSync(
			file,
			`${JSON.stringify({ dir, bytes: Buffer.from(bytes).toString("base64") })}\n`,
		);
	};

	const NativeWebSocket = globalThis.WebSocket;
	class CaptureWebSocket extends NativeWebSocket {
		constructor(url: string | URL, protocols?: string | string[]) {
			super(url, protocols);
			this.addEventListener("message", (event) => {
				if (inboundCaptured) return;
				const data = (event as MessageEvent).data;
				if (data instanceof ArrayBuffer) {
					inboundCaptured = true;
					record("s2c", new Uint8Array(data));
				} else if (data instanceof Uint8Array) {
					inboundCaptured = true;
					record("s2c", data);
				}
			});
		}

		send(data: string | ArrayBufferLike | Blob | ArrayBufferView): void {
			if (data instanceof Uint8Array) record("c2s", data);
			else if (data instanceof ArrayBuffer) record("c2s", new Uint8Array(data));
			super.send(data as string | ArrayBufferLike | Blob | ArrayBufferView);
		}
	}

	(globalThis as unknown as { WebSocket: typeof WebSocket }).WebSocket =
		CaptureWebSocket;
}
