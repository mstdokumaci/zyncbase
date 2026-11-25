import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { GlobalRegistrator } from "@happy-dom/global-registrator";

setDefaultTimeout(120_000);

const NativeFetch = globalThis.fetch;
const NativeWebSocket = globalThis.WebSocket;

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
const DATA_DIR = await mkdtemp(join(tmpdir(), "verso-ui-"));

GlobalRegistrator.register({ url: `http://localhost:${EDGE_PORT}/` });
globalThis.WebSocket = NativeWebSocket;
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
	const deadline = Date.now() + 60_000;
	while (Date.now() < deadline) {
		try {
			const response = await fetch(`http://127.0.0.1:${port}/health`);
			if (response.ok) return;
		} catch {}
		await Bun.sleep(200);
	}
	throw new Error("Verso dev server did not become ready");
}

let dev: Bun.Subprocess | undefined;

beforeAll(async () => {
	dev = Bun.spawn(["bun", "examples/verso/dev.ts"], {
		cwd: process.cwd(),
		env: {
			...process.env,
			VERSO_DEV_PORT: String(EDGE_PORT),
			VERSO_PORT: String(APP_PORT),
			VERSO_DB_PORT: String(DATABASE_PORT),
			VERSO_DATA_DIR: DATA_DIR,
		},
		stdout: "ignore",
		stderr: "ignore",
	});
	await waitForHealth(EDGE_PORT);
});

afterAll(async () => {
	cleanup();
	dev?.kill("SIGINT");
	await dev?.exited.catch(() => {});
	await GlobalRegistrator.unregister();
	await rm(DATA_DIR, { recursive: true, force: true });
});

test("joining opens the seeded welcome page in the editor", async () => {
	render(createElement(App));
	fireEvent.change(screen.getByPlaceholderText("you@example.com"), {
		target: { value: "ada@verso.test" },
	});
	fireEvent.change(screen.getByPlaceholderText("Ada"), {
		target: { value: "Ada Lovelace" },
	});
	fireEvent.click(screen.getByRole("button", { name: "Enter workspace" }));

	await waitFor(
		() => expect(screen.getByDisplayValue("Welcome")).toBeTruthy(),
		{ timeout: 30_000 },
	);
	await waitFor(
		() =>
			expect(document.querySelector(".prose")?.textContent ?? "").toContain(
				"Everything here is a row",
			),
		{ timeout: 30_000 },
	);
	expect(screen.getByText("Ada Lovelace")).toBeTruthy();

	// The local user is rendered once: awareness also carries this client.
	await waitFor(
		() =>
			expect(document.querySelectorAll(".page__tools .avatar")).toHaveLength(1),
		{ timeout: 10_000 },
	);

	// Connected before mount: no offline banner, and the pill says live.
	expect(document.querySelector(".notice")).toBeNull();
	expect(document.querySelector(".link-pill")?.textContent).toBe("live");

	// The seeded page was written by the service account, so it has no name;
	// a page this person creates names them in the meta line.
	expect(document.querySelector(".page__meta")?.textContent ?? "").toContain(
		"Created",
	);
	fireEvent.click(screen.getByText("+ New"));
	await waitFor(
		() =>
			expect(
				document.querySelector(".page__meta")?.textContent ?? "",
			).toContain("Ada Lovelace"),
		{ timeout: 30_000 },
	);
});
