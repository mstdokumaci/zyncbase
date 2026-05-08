import {
	afterAll,
	beforeAll,
	describe,
	setDefaultTimeout,
	test,
} from "bun:test";
import {
	buildServerIfNeeded,
	cleanupE2EArtifacts,
	resetE2ERoots,
	runE2ETest,
	withServer,
} from "./harness";
import { run as runBatch } from "./test-batch";
import { run as runErrors } from "./test-errors";
import { run as runFilters } from "./test-filters";
import { run as runPersistence } from "./test-persistence";
import { run as runSync } from "./test-sync";

setDefaultTimeout(120_000);

beforeAll(() => {
	buildServerIfNeeded();
	resetE2ERoots();
});

afterAll(() => {
	cleanupE2EArtifacts();
});

describe("ZyncBase E2E", () => {
	test("bi-directional sync, batch operations, and error reporting", async () => {
		await runE2ETest(
			"Bi-directional sync, batch operations, and errors",
			async (ctx) => {
				await withServer(
					ctx,
					{
						schemaPath: ctx.schemaPath("schema-sync.json"),
						dataDir: ctx.dataPath("sync"),
						configName: "zyncbase-config-sync.json",
						authPath: ctx.schemaPath("auth-allow-all.json"),
					},
					async ({ port }) => {
						await runSync(port);
						await runBatch(port);
						await runErrors(port);
					},
				);
			},
		);
	});

	test("persistence survives server restart", async () => {
		await runE2ETest("Persistence", async (ctx) => {
			const serverOptions = {
				schemaPath: ctx.schemaPath("schema-persistence.json"),
				dataDir: ctx.dataPath("persistence"),
				configName: "zyncbase-config-persistence.json",
			};

			await withServer(ctx, serverOptions, async ({ port }) => {
				await runPersistence("set", port, ctx.artifactDir);
			});
			await withServer(ctx, serverOptions, async ({ port }) => {
				await runPersistence("get", port, ctx.artifactDir);
			});
		});
	});

	test("filtered subscriptions stay consistent", async () => {
		await runE2ETest("Filtered subscriptions", async (ctx) => {
			await withServer(
				ctx,
				{
					schemaPath: ctx.schemaPath("schema-filters.json"),
					dataDir: ctx.dataPath("filters"),
					configName: "zyncbase-config-filters.json",
				},
				async ({ port }) => {
					await runFilters(port);
				},
			);
		});
	});
});
