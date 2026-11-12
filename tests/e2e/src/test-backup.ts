import * as fs from "node:fs";
import * as path from "node:path";

import { ZyncBaseClient } from "./client";
import { type E2ETestContext, SERVER_BIN, withServer } from "./harness";

type CliResult = {
	code: number;
	stdout: string;
	stderr: string;
};

const CLI_TIMEOUT_MS = 30_000;

function runCli(args: string[]): CliResult {
	const result = Bun.spawnSync([SERVER_BIN, ...args], {
		cwd: process.cwd(),
		timeout: CLI_TIMEOUT_MS,
	});
	return {
		code: result.exitCode ?? -1,
		stdout: result.stdout.toString(),
		stderr: result.stderr.toString(),
	};
}

function expectOk(result: CliResult, label: string): void {
	if (result.code !== 0) {
		throw new Error(
			`${label} failed with exit ${result.code}\n${result.stdout}\n${result.stderr}`,
		);
	}
}

export async function run(ctx: E2ETestContext): Promise<void> {
	const configName = "zyncbase-config-backup.json";
	const backupPath = ctx.artifactPath("snapshot.db");
	const serverOptions = {
		schemaPath: ctx.schemaPath("schema-persistence.json"),
		dataDir: ctx.dataPath("backup"),
		configName,
	};

	await withServer(ctx, serverOptions, async ({ port, configPath }) => {
		const client = new ZyncBaseClient(`ws://127.0.0.1:${port}`);
		await client.connect();
		try {
			await client.store.set(
				["persistence", "before"],
				{ status: "before", timestamp: 1 },
				{ confirm: "committed" },
			);
			await client.store.set(
				["persistence", "after"],
				{ status: "after", timestamp: 2 },
				{ confirm: "committed" },
			);

			expectOk(
				runCli(["backup", backupPath, "--config", configPath]),
				"backup while running",
			);
			expectOk(runCli(["verify", backupPath]), "verify snapshot");

			const lockedRestore = runCli([
				"restore",
				backupPath,
				"--config",
				configPath,
			]);
			if (lockedRestore.code === 0) {
				throw new Error("restore succeeded while the server was running");
			}
			if (!lockedRestore.stderr.includes("DataDirLocked")) {
				throw new Error(`expected DataDirLocked, got: ${lockedRestore.stderr}`);
			}

			const duplicate = runCli(["backup", backupPath, "--config", configPath]);
			if (duplicate.code === 0) {
				throw new Error("backup overwrote an existing snapshot");
			}

			// Written after the snapshot; must not survive the restore.
			await client.store.set(
				["persistence", "newer"],
				{ status: "newer", timestamp: 3 },
				{ confirm: "committed" },
			);
		} finally {
			client.close();
		}
	});

	expectOk(
		runCli(["restore", backupPath, "--config", ctx.artifactPath(configName)]),
		"restore",
	);

	await withServer(ctx, serverOptions, async ({ port }) => {
		const client = new ZyncBaseClient(`ws://127.0.0.1:${port}`);
		await client.connect();
		try {
			const before = await client.get("public", ["persistence", "before"]);
			const after = await client.get("public", ["persistence", "after"]);
			const newer = await client.get("public", ["persistence", "newer"]);

			if (!before) throw new Error("snapshot record missing after restore");
			if (!after)
				throw new Error("second snapshot record missing after restore");
			if (newer) throw new Error("post-snapshot record present after restore");
		} finally {
			client.close();
		}
	});

	const drillDir = ctx.dataPath("backup-drill");
	expectOk(
		runCli(["restore", backupPath, "--data-dir", drillDir]),
		"restore to a new data dir",
	);
	if (!fs.existsSync(path.join(drillDir, "zyncbase.db"))) {
		throw new Error("restore --data-dir did not create zyncbase.db");
	}

	const corruptPath = ctx.artifactPath("corrupt.db");
	fs.copyFileSync(backupPath, corruptPath);
	fs.truncateSync(corruptPath, 100);
	const corrupt = runCli([
		"restore",
		corruptPath,
		"--config",
		ctx.artifactPath(configName),
	]);
	if (corrupt.code === 0) {
		throw new Error("restored a corrupt snapshot");
	}

	// The rejected restore must leave the stopped server's existing data intact.
	await withServer(ctx, serverOptions, async ({ port }) => {
		const client = new ZyncBaseClient(`ws://127.0.0.1:${port}`);
		await client.connect();
		try {
			const before = await client.get("public", ["persistence", "before"]);
			const after = await client.get("public", ["persistence", "after"]);
			const newer = await client.get("public", ["persistence", "newer"]);

			if (!before)
				throw new Error("record lost after rejected corrupt restore");
			if (!after)
				throw new Error("second record lost after rejected corrupt restore");
			if (newer)
				throw new Error(
					"post-snapshot record reappeared after rejected restore",
				);
		} finally {
			client.close();
		}
	});
}
