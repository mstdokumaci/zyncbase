import { expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
	computeAssetsHash,
	type DeployRunner,
	deployIfChanged,
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
		const calls: string[][] = [];
		const run: DeployRunner = async (command) => {
			calls.push(command);
			return 0;
		};
		const options = {
			assetsDir: assets,
			stateDir: state,
			command: ["wrangler", "deploy"],
			cwd: root,
			run,
		};
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
		let code = 1;
		const options = {
			assetsDir: assets,
			stateDir: state,
			command: ["wrangler", "deploy"],
			cwd: root,
			run: async () => code,
		};
		expect(await deployIfChanged(options)).toBe("failed");
		code = 0;
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
		const runner: DeployRunner = async () => {
			called = true;
			return 0;
		};
		const options = {
			assetsDir: assets,
			stateDir: state,
			command: ["wrangler", "deploy"],
			cwd: root,
			run: runner,
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
