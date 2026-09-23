import { createHash } from "node:crypto";
import { mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises";
import { extname, join, relative, sep } from "node:path";

export type DeployResult = "deployed" | "unchanged" | "skipped" | "failed";
export type AssetManifest = Record<string, { hash: string; size: number }>;
export type Publish = (assetsDir: string) => Promise<void>;

const HASH_FILE = "deploy-hash";
const API = "https://api.cloudflare.com/client/v4";
const API_TIMEOUT_MS = 120_000;
// Assets-only Workers still carry a module so misses have a defined response.
const NOOP_MODULE =
	'export default { fetch() { return new Response("Not found", { status: 404 }); } };\n';
const MIME_TYPES: Record<string, string> = {
	html: "text/html",
	js: "text/javascript",
	css: "text/css",
	json: "application/json",
	png: "image/png",
	svg: "image/svg+xml",
};

/** sha256 over sorted relative paths and contents of every asset file. */
export async function computeAssetsHash(assetsDir: string): Promise<string> {
	const files: string[] = [];
	const walk = async (dir: string) => {
		for (const entry of await readdir(dir, { withFileTypes: true })) {
			const path = join(dir, entry.name);
			if (entry.isDirectory()) await walk(path);
			else if (entry.isFile()) files.push(path);
		}
	};
	await walk(assetsDir);
	files.sort();
	const hash = createHash("sha256");
	for (const file of files) {
		hash.update(relative(assetsDir, file));
		hash.update(await readFile(file));
	}
	return hash.digest("hex");
}

/**
 * Deploys the asset directory only when its content hash changed since the
 * last successful deploy. Failures never throw; the caller may retry.
 */
export async function deployIfChanged(options: {
	assetsDir: string;
	stateDir: string;
	publish: Publish;
	log?: (message: string) => void;
}): Promise<DeployResult> {
	const { assetsDir, stateDir, publish, log = () => {} } = options;
	if (!(await exists(join(assetsDir, "index.html")))) {
		log("Deploy skipped: assets directory has no index.html");
		return "skipped";
	}
	const hash = await computeAssetsHash(assetsDir);
	const stateFile = join(stateDir, HASH_FILE);
	const previous = await readFile(stateFile, "utf8").catch(() => "");
	if (previous.trim() === hash) return "unchanged";
	try {
		await publish(assetsDir);
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		log(`Deploy failed: ${message}`);
		return "failed";
	}
	await mkdir(stateDir, { recursive: true });
	await writeFile(stateFile, hash);
	return "deployed";
}

/** Manifest for the Workers assets-upload-session call. */
export async function buildAssetManifest(
	assetsDir: string,
): Promise<AssetManifest> {
	const manifest: AssetManifest = {};
	const walk = async (dir: string) => {
		for (const entry of await readdir(dir, { withFileTypes: true })) {
			const path = join(dir, entry.name);
			if (entry.isDirectory()) {
				await walk(path);
			} else if (entry.isFile()) {
				const content = await readFile(path);
				const relativePath = `/${relative(assetsDir, path).split(sep).join("/")}`;
				const extension = extname(relativePath).slice(1);
				manifest[relativePath] = {
					hash: createHash("sha256")
						.update(content.toString("base64"))
						.update(extension)
						.digest("hex")
						.slice(0, 32),
					size: content.byteLength,
				};
			}
		}
	};
	await walk(assetsDir);
	return manifest;
}

/**
 * Publishes the asset directory through the Cloudflare Workers API: create an
 * asset upload session, upload the returned buckets as base64 parts, then PUT
 * the Worker metadata with the completion token. No wrangler or workerd.
 */
export async function publishAssets(
	assetsDir: string,
	options: {
		accountId: string;
		apiToken: string;
		configPath: string;
		fetch?: typeof fetch;
		log?: (message: string) => void;
	},
): Promise<void> {
	const {
		accountId,
		apiToken,
		configPath,
		fetch: fetchImpl = globalThis.fetch,
		log = () => {},
	} = options;
	const config = await readWorkerConfig(configPath);
	const manifest = await buildAssetManifest(assetsDir);
	const files = Object.keys(manifest).length;
	log(`Publishing ${files} assets to Worker "${config.name}"...`);

	const session = await apiCall(
		fetchImpl,
		`${API}/accounts/${accountId}/workers/scripts/${config.name}/assets-upload-session`,
		{
			method: "POST",
			headers: {
				Authorization: `Bearer ${apiToken}`,
				"Content-Type": "application/json",
			},
			body: JSON.stringify({ manifest }),
		},
		"start the asset upload session",
	);
	const uploadToken = session.jwt;
	if (typeof uploadToken !== "string")
		throw new Error("Asset upload session returned no token");
	let completionToken = uploadToken;
	const pathsByHash = new Map(
		Object.entries(manifest).map(([path, entry]) => [entry.hash, path]),
	);
	const buckets = Array.isArray(session.buckets)
		? (session.buckets as string[][])
		: [];
	for (const bucket of buckets) {
		const form = new FormData();
		for (const hash of bucket) {
			const path = pathsByHash.get(hash);
			if (!path) throw new Error(`Upload bucket has unknown hash ${hash}`);
			const content = await readFile(join(assetsDir, path));
			form.append(
				hash,
				new Blob([content.toString("base64")], { type: mimeType(path) }),
				hash,
			);
		}
		const uploaded = await apiCall(
			fetchImpl,
			`${API}/accounts/${accountId}/workers/assets/upload?base64=true`,
			{
				method: "POST",
				headers: { Authorization: `Bearer ${uploadToken}` },
				body: form,
			},
			"upload assets",
		);
		if (typeof uploaded.jwt === "string") completionToken = uploaded.jwt;
	}

	const form = new FormData();
	form.append(
		"metadata",
		new Blob(
			[
				JSON.stringify({
					main_module: "noop.js",
					assets: { jwt: completionToken },
					compatibility_date: config.compatibilityDate,
				}),
			],
			{ type: "application/json" },
		),
	);
	form.append(
		"noop.js",
		new Blob([NOOP_MODULE], { type: "application/javascript+module" }),
		"noop.js",
	);
	await apiCall(
		fetchImpl,
		`${API}/accounts/${accountId}/workers/scripts/${config.name}`,
		{
			method: "PUT",
			headers: { Authorization: `Bearer ${apiToken}` },
			body: form,
		},
		"publish the Worker",
	);
	log(`Worker "${config.name}" published with ${files} assets.`);
}

async function apiCall(
	fetchImpl: typeof fetch,
	url: string,
	init: RequestInit,
	action: string,
): Promise<Record<string, unknown>> {
	const response = await fetchImpl(url, {
		...init,
		signal: init.signal ?? AbortSignal.timeout(API_TIMEOUT_MS),
	});
	const text = await response.text();
	let body: { result?: unknown; errors?: { message?: string }[] } = {};
	try {
		body = text ? JSON.parse(text) : {};
	} catch {
		// Non-JSON error pages fall back to the status text below.
	}
	if (!response.ok) {
		const detail =
			body.errors?.[0]?.message ?? `${response.status} ${response.statusText}`;
		throw new Error(`Failed to ${action}: ${detail}`);
	}
	const result = body.result;
	return (result && typeof result === "object" ? result : body) as Record<
		string,
		unknown
	>;
}

async function readWorkerConfig(configPath: string) {
	const source = await readFile(configPath, "utf8");
	const parsed = Bun.JSONC.parse(source) as {
		name?: unknown;
		compatibility_date?: unknown;
	};
	if (typeof parsed.name !== "string" || !parsed.name)
		throw new Error("wrangler.jsonc is missing a Worker name");
	if (
		typeof parsed.compatibility_date !== "string" ||
		!parsed.compatibility_date
	)
		throw new Error("wrangler.jsonc is missing compatibility_date");
	return { name: parsed.name, compatibilityDate: parsed.compatibility_date };
}

function mimeType(path: string) {
	return (
		MIME_TYPES[extname(path).slice(1).toLowerCase()] ??
		"application/octet-stream"
	);
}

async function exists(path: string) {
	try {
		await stat(path);
		return true;
	} catch {
		return false;
	}
}
