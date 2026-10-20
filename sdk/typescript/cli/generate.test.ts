import { describe, expect, setDefaultTimeout, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { generateTypes, type SchemaFile, validateSchema } from "./generate";

// tsc spawns are slow — give the compile test plenty of time
setDefaultTimeout(120_000);

const sampleSchema: SchemaFile = {
	version: "1.0.0",
	store: {
		users: {
			unique: [["profile", "handle"]],
			fields: {
				name: { type: "string" },
				score: { type: "integer" },
				profile: {
					type: "object",
					fields: {
						handle: { type: "string" },
						address: {
							type: "object",
							fields: { city: { type: "string" } },
						},
					},
				},
			},
		},
		chunks: {
			required: ["color_indexes", "label"],
			unique: [["label"]],
			fields: {
				color_indexes: { type: "bytes" },
				label: { type: "string" },
				meta: {
					type: "object",
					fields: { created: { type: "integer" } },
				},
			},
		},
	},
};

describe("generateTypes", () => {
	test("emits required, optional, nested, and bytes fields", () => {
		const output = generateTypes(sampleSchema.store);

		expect(output).toContain("export type ZyncBaseSchema = {");
		expect(output).toContain("color_indexes: Uint8Array;");
		expect(output).toContain("label: string;");
		expect(output).toContain("name?: string;");
		expect(output).toContain("handle?: string;");
		expect(output).toContain("city?: string;");
		expect(output).not.toContain("ValidPaths");
	});
});

describe("validateSchema", () => {
	test("accepts the sample schema", () => {
		expect(validateSchema(sampleSchema)).toBeNull();
	});

	test("rejects a required field that does not exist", () => {
		const schema: SchemaFile = {
			version: "1.0.0",
			store: { users: { required: ["missing"], fields: {} } },
		};
		expect(validateSchema(schema)).toContain(
			'requires unknown field "missing"',
		);
	});

	test("rejects a unique constraint on an unknown nested path", () => {
		const schema: SchemaFile = {
			version: "1.0.0",
			store: {
				users: {
					unique: [["profile", "missing"]],
					fields: {
						profile: {
							type: "object",
							fields: { handle: { type: "string" } },
						},
					},
				},
			},
		};
		expect(validateSchema(schema)).toContain("unique constraint on unknown");
	});

	test("rejects unsupported field types", () => {
		const schema = {
			version: "1.0.0",
			store: {
				users: {
					fields: { whatever: { type: "uuid" } },
				},
			},
		} as unknown as SchemaFile;
		expect(validateSchema(schema)).toContain('unsupported type "uuid"');
	});

	test("rejects reserved flattening separators and bad identifiers", () => {
		const reserved: SchemaFile = {
			version: "1.0.0",
			store: { users: { fields: { a__b: { type: "string" } } } },
		};
		expect(validateSchema(reserved)).toContain('contains "__"');

		const bad: SchemaFile = {
			version: "1.0.0",
			store: { "1users": { fields: {} } },
		};
		expect(validateSchema(bad)).toContain("Invalid collection name");
	});

	test("rejects a missing version", () => {
		const schema = { store: {} } as SchemaFile;
		expect(validateSchema(schema)).toContain('non-empty "version"');
	});
});

describe("generated schema compiles against the typed Store", () => {
	test("generated interface drives path and value typing", () => {
		const typesContent = generateTypes(sampleSchema.store);

		const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "zyncbase-cli-"));
		const typesFile = path.join(tmpDir, "zync-types.ts");
		const consumerFile = path.join(tmpDir, "consumer.ts");
		const sdkTypes = path
			.resolve(import.meta.dir, "../src/types.ts")
			.replace(/\\/g, "/");

		const consumer = `import type { Store } from "${sdkTypes}";
import type { ZyncBaseSchema } from "./zync-types";

declare const store: Store<ZyncBaseSchema>;

const name: string | undefined = await store.get("users.u1.name");
const bytes: Uint8Array | undefined = await store.get([
	"chunks",
	"c1",
	"color_indexes",
]);
const city: string | undefined = await store.get([
	"users",
	"u1",
	"profile",
	"address",
	"city",
]);
const id: string = (await store.query("chunks"))[0].id;
await store.set("users.u1.name", null);
await store.set(["users", "u1", "score"], 4);
// @ts-expect-error wrong value type
await store.set("users.u1.name", 42);
// @ts-expect-error unknown collection
await store.get("nope.u1");
// @ts-expect-error unknown field in tuple form
await store.get(["users", "u1", "nope"]);
// @ts-expect-error missing required field
await store.create("chunks", { label: "a" });
void name;
void bytes;
void city;
void id;
`;

		try {
			Bun.write(typesFile, typesContent);
			Bun.write(consumerFile, consumer);

			const tscPath = new URL("../node_modules/.bin/tsc", import.meta.url)
				.pathname;
			const result = Bun.spawnSync([
				tscPath,
				"--noEmit",
				"--strict",
				"--target",
				"ESNext",
				"--module",
				"ESNext",
				"--moduleResolution",
				"bundler",
				"--skipLibCheck",
				"--allowImportingTsExtensions",
				consumerFile,
			]);

			expect(result.stderr.toString()).toBe("");
			expect(result.exitCode).toBe(0);
		} finally {
			fs.rmSync(tmpDir, { recursive: true, force: true });
		}
	});
});
