import { expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
	buildAssetManifest,
	computeAssetsHash,
	deployIfChanged,
	publishAssets,
} from "./deploy";

async function setup() {
	const root = await mkdtemp(join(tmpdir(), "pixel-deploy-"));
	const assets = join(root, "assets");
	const state = join(root, "state");
	await mkdir(assets, { recursive: true });
	await mkdir(state, { recursive: true });
	await writeFile(join(assets, "index.html"), "page");
	return { root, assets, state };
}

test("asset hash tracks file content and layout", async () => {
	const { root, assets } = await setup();
	try {
		const first = await computeAssetsHash(assets);
		await writeFile(join(assets, "index.html"), "changed");
		const second = await computeAssetsHash(assets);
		expect(second).not.toBe(first);
		await writeFile(join(assets, "index.html"), "page");
		expect(await computeAssetsHash(assets)).toBe(first);
	} finally {
		await rm(root, { recursive: true, force: true });
	}
});

test("deploy runs only when the hash changed", async () => {
	const { root, assets, state } = await setup();
	try {
		const calls: string[] = [];
		const publish = async () => {
			calls.push("publish");
		};
		const options = { assetsDir: assets, stateDir: state, publish };
		expect(await deployIfChanged(options)).toBe("deployed");
		expect(calls).toHaveLength(1);
		expect(await deployIfChanged(options)).toBe("unchanged");
		expect(calls).toHaveLength(1);
		await mkdir(join(assets, "history"), { recursive: true });
		await writeFile(join(assets, "history", "1.json"), "{}");
		expect(await deployIfChanged(options)).toBe("deployed");
		expect(calls).toHaveLength(2);
	} finally {
		await rm(root, { recursive: true, force: true });
	}
});

test("a failed deploy keeps the old hash so the next boot retries", async () => {
	const { root, assets, state } = await setup();
	try {
		let fail = true;
		const options = {
			assetsDir: assets,
			stateDir: state,
			publish: async () => {
				if (fail) throw new Error("network down");
			},
		};
		expect(await deployIfChanged(options)).toBe("failed");
		fail = false;
		expect(await deployIfChanged(options)).toBe("deployed");
		expect(await deployIfChanged(options)).toBe("unchanged");
	} finally {
		await rm(root, { recursive: true, force: true });
	}
});

test("deploy skips an assets directory without index.html", async () => {
	const { root, assets, state } = await setup();
	try {
		await rm(join(assets, "index.html"));
		let called = false;
		const options = {
			assetsDir: assets,
			stateDir: state,
			publish: async () => {
				called = true;
			},
		};
		expect(await deployIfChanged(options)).toBe("skipped");
		expect(called).toBe(false);
		// A missing assets directory must skip, not throw while hashing.
		await rm(assets, { recursive: true, force: true });
		expect(await deployIfChanged(options)).toBe("skipped");
		expect(called).toBe(false);
	} finally {
		await rm(root, { recursive: true, force: true });
	}
});

test("asset manifest hashes every file with its extension", async () => {
	const { root, assets } = await setup();
	try {
		await mkdir(join(assets, "history"), { recursive: true });
		await writeFile(
			join(assets, "history", "1.png"),
			Buffer.from([1, 2, 3, 4]),
		);
		const manifest = await buildAssetManifest(assets);
		expect(Object.keys(manifest).sort()).toEqual([
			"/history/1.png",
			"/index.html",
		]);
		expect(manifest["/index.html"].size).toBe(4);
		expect(manifest["/history/1.png"].size).toBe(4);
		expect(manifest["/index.html"].hash).toMatch(/^[0-9a-f]{32}$/);
		// Same bytes, different extension: hashes must differ.
		await writeFile(join(assets, "same.txt"), "page");
		const withText = await buildAssetManifest(assets);
		expect(withText["/same.txt"].hash).not.toBe(withText["/index.html"].hash);
		// Deterministic across runs.
		expect(await buildAssetManifest(assets)).toEqual(withText);
	} finally {
		await rm(root, { recursive: true, force: true });
	}
});

test("publishAssets runs session, upload, and script calls", async () => {
	const { root, assets } = await setup();
	try {
		await mkdir(join(assets, "history"), { recursive: true });
		await writeFile(
			join(assets, "history", "1.png"),
			Buffer.from([1, 2, 3, 4]),
		);
		const configPath = join(root, "wrangler.jsonc");
		await writeFile(
			configPath,
			`{
	// Worker identity lives here.
	"name": "pixel-conquest",
	"compatibility_date": "2026-09-08",
	"assets": { "directory": "./dist" }
}`,
		);
		const manifest = await buildAssetManifest(assets);
		const indexHash = manifest["/index.html"]?.hash ?? "";
		const pngHash = manifest["/history/1.png"]?.hash ?? "";
		const calls: { url: string; init: RequestInit }[] = [];
		const fetchImpl = (async (
			input: string | URL | Request,
			init?: RequestInit,
		) => {
			const url = String(input);
			calls.push({ url, init: init ?? {} });
			if (url.endsWith("/assets-upload-session")) {
				return new Response(
					JSON.stringify({
						success: true,
						result: { buckets: [[indexHash, pngHash]], jwt: "upload-token" },
					}),
					{ status: 200 },
				);
			}
			if (url.includes("/workers/assets/upload")) {
				return new Response(
					JSON.stringify({
						success: true,
						result: { jwt: "completion-token" },
					}),
					{ status: 201 },
				);
			}
			if (url.endsWith("/workers/scripts/pixel-conquest")) {
				return new Response(JSON.stringify({ success: true, result: {} }), {
					status: 200,
				});
			}
			throw new Error(`Unexpected URL: ${url}`);
		}) as typeof fetch;

		await publishAssets(assets, {
			accountId: "acct",
			apiToken: "token",
			configPath,
			fetch: fetchImpl,
		});
		expect(calls).toHaveLength(3);

		expect(calls[0]?.url).toBe(
			"https://api.cloudflare.com/client/v4/accounts/acct/workers/scripts/pixel-conquest/assets-upload-session",
		);
		expect(calls[0]?.init.method).toBe("POST");
		expect(new Headers(calls[0]?.init.headers).get("Authorization")).toBe(
			"Bearer token",
		);
		const sessionBody = JSON.parse(String(calls[0]?.init.body));
		expect(Object.keys(sessionBody.manifest).sort()).toEqual([
			"/history/1.png",
			"/index.html",
		]);
		expect(sessionBody.manifest["/index.html"].hash).toBe(indexHash);

		expect(calls[1]?.url).toBe(
			"https://api.cloudflare.com/client/v4/accounts/acct/workers/assets/upload?base64=true",
		);
		expect(new Headers(calls[1]?.init.headers).get("Authorization")).toBe(
			"Bearer upload-token",
		);
		const uploadForm = calls[1]?.init.body as FormData;
		const htmlPart = uploadForm.get(indexHash) as Blob;
		// Bun may append a charset parameter for text/* types.
		expect(htmlPart.type).toStartWith("text/html");
		expect(await htmlPart.text()).toBe(Buffer.from("page").toString("base64"));
		expect((uploadForm.get(pngHash) as Blob).type).toStartWith("image/png");

		expect(calls[2]?.url).toBe(
			"https://api.cloudflare.com/client/v4/accounts/acct/workers/scripts/pixel-conquest",
		);
		expect(calls[2]?.init.method).toBe("PUT");
		expect(new Headers(calls[2]?.init.headers).get("Authorization")).toBe(
			"Bearer token",
		);
		const deployForm = calls[2]?.init.body as FormData;
		const metadata = JSON.parse(
			await (deployForm.get("metadata") as Blob).text(),
		);
		expect(metadata.assets.jwt).toBe("completion-token");
		expect(metadata.main_module).toBe("noop.js");
		expect(metadata.compatibility_date).toBe("2026-09-08");
		expect(await (deployForm.get("noop.js") as Blob).text()).toContain(
			"export default",
		);
	} finally {
		await rm(root, { recursive: true, force: true });
	}
});

test("publishAssets reuses the session token when nothing needs uploading", async () => {
	const { root, assets } = await setup();
	try {
		const configPath = join(root, "wrangler.jsonc");
		await writeFile(
			configPath,
			JSON.stringify({ name: "w", compatibility_date: "2026-01-01" }),
		);
		const calls: string[] = [];
		const fetchImpl = (async (input: string | URL | Request) => {
			const url = String(input);
			calls.push(url);
			if (url.endsWith("/assets-upload-session")) {
				return new Response(
					JSON.stringify({
						success: true,
						result: { buckets: [], jwt: "session-token" },
					}),
					{ status: 200 },
				);
			}
			return new Response(JSON.stringify({ success: true, result: {} }), {
				status: 200,
			});
		}) as typeof fetch;
		await publishAssets(assets, {
			accountId: "acct",
			apiToken: "token",
			configPath,
			fetch: fetchImpl,
		});
		expect(calls).toHaveLength(2);
		expect(calls[1]?.endsWith("/workers/scripts/w")).toBe(true);
	} finally {
		await rm(root, { recursive: true, force: true });
	}
});

test("publishAssets surfaces API error messages", async () => {
	const { root, assets } = await setup();
	try {
		const configPath = join(root, "wrangler.jsonc");
		await writeFile(
			configPath,
			JSON.stringify({ name: "w", compatibility_date: "2026-01-01" }),
		);
		const fetchImpl = (async () =>
			new Response(
				JSON.stringify({
					success: false,
					errors: [{ message: "Authentication error" }],
				}),
				{ status: 403 },
			)) as typeof fetch;
		await expect(
			publishAssets(assets, {
				accountId: "acct",
				apiToken: "bad",
				configPath,
				fetch: fetchImpl,
			}),
		).rejects.toThrow(
			"Failed to start the asset upload session: Authentication error",
		);
	} finally {
		await rm(root, { recursive: true, force: true });
	}
});
