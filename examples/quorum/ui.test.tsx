import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { GlobalRegistrator } from "@happy-dom/global-registrator";

setDefaultTimeout(120_000);

const NativeWebSocket = globalThis.WebSocket;
const NativeFetch = globalThis.fetch;

async function freePort(): Promise<number> {
	const probe = createServer();
	await new Promise<void>((resolve, reject) => {
		probe.once("error", reject);
		probe.listen(0, "127.0.0.1", resolve);
	});
	const address = probe.address();
	if (!address || typeof address === "string") throw new Error("No port");
	await new Promise<void>((resolve, reject) =>
		probe.close((error) => (error ? reject(error) : resolve())),
	);
	return address.port;
}

const [EDGE_PORT, APP_PORT, DATABASE_PORT] = await Promise.all([
	freePort(),
	freePort(),
	freePort(),
]);
const DATA_DIR = await mkdtemp(join(tmpdir(), "quorum-ui-"));

GlobalRegistrator.register({
	url: `http://localhost:${EDGE_PORT}/`,
});
globalThis.WebSocket = NativeWebSocket;
// Bun's native fetch does not resolve browser-relative URLs. The app uses
// "/session" in the browser; resolve it to the test edge here.
globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
	if (typeof input === "string" && input.startsWith("/")) {
		return NativeFetch(`http://localhost:${EDGE_PORT}${input}`, init);
	}
	return NativeFetch(input, init);
}) as typeof fetch;

const { render, screen, fireEvent, waitFor, cleanup } = await import(
	"@testing-library/react"
);
const { createElement } = await import("react");
const { App } = await import("./app");

async function waitForHealth(port: number): Promise<void> {
	const deadline = Date.now() + 45_000;
	while (Date.now() < deadline) {
		try {
			const response = await fetch(`http://127.0.0.1:${port}/health`);
			if (response.ok) return;
		} catch {}
		await Bun.sleep(200);
	}
	throw new Error("Quorum dev server did not become ready");
}

let dev: Bun.Subprocess | undefined;

beforeAll(async () => {
	dev = Bun.spawn(["bun", "examples/quorum/dev.ts"], {
		cwd: process.cwd(),
		env: {
			...process.env,
			QUORUM_DEV_PORT: String(EDGE_PORT),
			QUORUM_PORT: String(APP_PORT),
			QUORUM_DB_PORT: String(DATABASE_PORT),
			QUORUM_DATA_DIR: DATA_DIR,
		},
		stdout: "ignore",
		stderr: "ignore",
	});
	await waitForHealth(EDGE_PORT);
});

afterAll(async () => {
	if (dev) {
		dev.kill("SIGINT");
		await dev.exited.catch(() => {});
	}
	await GlobalRegistrator.unregister();
	await rm(DATA_DIR, { recursive: true, force: true });
});

test("the landing can run a demo room through reveal", async () => {
	const originalSetItem = Storage.prototype.setItem;
	// The credential must survive even when localStorage is unavailable.
	Storage.prototype.setItem = () => {
		throw new Error("storage blocked");
	};
	render(createElement(App));
	fireEvent.change(screen.getByLabelText("Your name"), {
		target: { value: "UI Host" },
	});
	fireEvent.click(screen.getByRole("button", { name: "Try the demo" }));

	await waitFor(
		() => expect(screen.getByText("Demo: Sprint 42")).toBeTruthy(),
		{ timeout: 20_000 },
	);
	expect(document.cookie).toContain("quorum_credential=");

	await waitFor(
		() =>
			expect(
				(
					screen.getByRole("button", {
						name: "Start voting",
					}) as HTMLButtonElement
				).disabled,
			).toBe(false),
		{ timeout: 10_000 },
	);
	fireEvent.click(screen.getByRole("button", { name: "Start voting" }));
	await waitFor(() => expect(screen.getByText(/votes left/)).toBeTruthy(), {
		timeout: 10_000,
	});

	const addVote = screen.getAllByRole("button", { name: "Add one vote" })[0];
	fireEvent.click(addVote);
	await waitFor(
		() =>
			expect(
				screen.getByText(
					(_, element) =>
						element?.tagName === "STRONG" &&
						/4\s*of\s*5\s*votes left/.test(element.textContent ?? ""),
				),
			).toBeTruthy(),
		{ timeout: 10_000 },
	);

	const originalConfirm = window.confirm;
	window.confirm = () => true;
	fireEvent.click(screen.getByRole("button", { name: "Close and reveal" }));
	await waitFor(
		() => expect(screen.getByText("The room has decided.")).toBeTruthy(),
		{ timeout: 15_000 },
	);
	window.confirm = originalConfirm;

	cleanup();
	Storage.prototype.setItem = originalSetItem;
});
