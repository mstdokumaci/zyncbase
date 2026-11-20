import * as fs from "node:fs";
import * as path from "node:path";

import { ZyncBaseClient } from "./client";
import {
	type E2ETestContext,
	expectOk,
	runCli,
	startServerExpectFailure,
	withServer,
} from "./harness";

const v1 = {
	version: "1.0.0",
	store: {
		tasks: {
			fields: {
				title: { type: "string" },
				priority: { type: "integer" },
				assignee: { type: "string" },
			},
			required: ["title"],
		},
	},
};

// priority becomes a string enum and assignee is removed: migration required.
const v2 = {
	version: "2.0.0",
	store: {
		tasks: {
			fields: {
				title: { type: "string" },
				priority: { type: "string", enum: ["low", "medium", "high"] },
			},
			required: ["title"],
		},
	},
};

const conversion = `INSERT INTO "tasks" ("id", "namespace_id", "owner_id", "title", "priority", "created_at", "updated_at")
SELECT "id", "namespace_id", "owner_id", "title",
       CASE "priority" WHEN 1 THEN 'low' WHEN 2 THEN 'medium' ELSE 'high' END,
       "created_at", "updated_at"
FROM "_zync_prev_tasks";
`;

type Task = { title?: unknown; priority?: unknown; assignee?: unknown };

function expectIncludes(text: string, needle: string, label: string): void {
	if (!text.includes(needle)) {
		throw new Error(
			`${label}: expected output to contain "${needle}"\n${text}`,
		);
	}
}

export async function run(ctx: E2ETestContext): Promise<void> {
	// The migrations directory defaults to <schema dir>/migrations.
	const projectDir = ctx.artifactPath("project");
	const schemaPath = path.join(projectDir, "schema.json");
	const migrationsDir = path.join(projectDir, "migrations");
	fs.mkdirSync(projectDir, { recursive: true });
	const writeSchema = (schema: unknown) =>
		fs.writeFileSync(schemaPath, JSON.stringify(schema, null, "\t"));

	const serverOptions = {
		schemaPath,
		dataDir: ctx.dataPath("migrations"),
		configName: "zyncbase-config-migrations.json",
		authPath: ctx.schemaPath("auth-allow-all.json"),
	};
	const configPath = ctx.artifactPath(serverOptions.configName);

	writeSchema(v1);
	await withServer(ctx, serverOptions, async ({ port }) => {
		const client = new ZyncBaseClient(`ws://127.0.0.1:${port}`);
		await client.connect();
		try {
			if (client.schemaVersion !== "1.0.0") {
				throw new Error(`client sees schema ${client.schemaVersion}`);
			}
			const rows: [string, number][] = [
				["a", 1],
				["b", 2],
				["c", 9],
			];
			for (const [id, priority] of rows) {
				await client.store.set(["tasks", id], {
					title: `task ${id}`,
					priority,
					assignee: "ann",
				});
			}
		} finally {
			client.close();
		}
	});

	// A destructive change without a migration refuses to start.
	writeSchema(v2);
	const refused = await startServerExpectFailure(ctx, serverOptions);
	expectIncludes(refused.stderr, "schema.json needs a migration", "server");
	expectIncludes(refused.stderr, "zyncbase migrate new", "server");
	expectIncludes(refused.stderr, "Nothing was changed.", "server");

	const blocked = runCli(["migrate", "status", "--config", configPath]);
	if (blocked.code === 0) {
		throw new Error(`migrate status passed a blocked start\n${blocked.stdout}`);
	}
	expectIncludes(blocked.stdout, "tasks.priority  type changed", "status");

	expectOk(
		runCli(["migrate", "new", "priority_to_string", "--config", configPath]),
		"migrate new",
	);
	const folders = fs
		.readdirSync(migrationsDir)
		.filter((name) => !name.startsWith("."));
	const folder = folders[0];
	if (folders.length !== 1 || !folder?.endsWith("_priority_to_string")) {
		throw new Error(`unexpected migration folders: ${folders.join(", ")}`);
	}
	const sqlPath = path.join(migrationsDir, folder, "migration.sql");
	expectIncludes(fs.readFileSync(sqlPath, "utf8"), "zync_todo('", "scaffold");

	const unresolved = runCli(["migrate", "check", "--config", configPath]);
	if (unresolved.code === 0) {
		throw new Error("migrate check accepted an unresolved zync_todo");
	}
	expectIncludes(unresolved.stdout, "unresolved decision", "check");

	fs.writeFileSync(sqlPath, conversion);
	expectOk(
		runCli(["migrate", "check", "--config", configPath]),
		"migrate check",
	);
	const dryRun = runCli([
		"migrate",
		"apply",
		"--dry-run",
		"--config",
		configPath,
	]);
	expectOk(dryRun, "migrate apply --dry-run");
	expectIncludes(dryRun.stdout, "rolled back", "dry run");

	// The next start applies the migration.
	await withServer(ctx, serverOptions, async ({ port }) => {
		const client = new ZyncBaseClient(`ws://127.0.0.1:${port}`);
		await client.connect();
		try {
			if (client.schemaVersion !== "2.0.0") {
				throw new Error(`client sees schema ${client.schemaVersion}`);
			}
			const expected: Record<string, string> = {
				a: "low",
				b: "medium",
				c: "high",
			};
			for (const [id, priority] of Object.entries(expected)) {
				const task = (await client.get("public", ["tasks", id])) as Task | null;
				if (task?.priority !== priority || task.title !== `task ${id}`) {
					throw new Error(
						`task ${id} after migration: ${JSON.stringify(task)}`,
					);
				}
				if (task.assignee !== undefined) {
					throw new Error(`task ${id} still has the removed assignee field`);
				}
			}
		} finally {
			client.close();
		}
	});

	const snapshots = fs
		.readdirSync(serverOptions.dataDir)
		.filter((name) => name.startsWith(`zyncbase.db.pre-migration-${folder}-`));
	if (snapshots.length !== 1) {
		throw new Error(`expected one pre-migration snapshot, found ${snapshots}`);
	}

	const upToDate = runCli(["migrate", "status", "--config", configPath]);
	expectOk(upToDate, "migrate status after the migration");
	expectIncludes(upToDate.stdout, `${folder}  applied`, "status");
	expectIncludes(upToDate.stdout, "Up to date", "status");
}
