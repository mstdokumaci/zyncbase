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
				role: { type: "string", enum: ["admin", "player"] },
				tags: { type: "array" },
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
	actions: {
		player_join: {
			params: {
				name: { type: "string" },
				country_id: { type: "integer" },
				session_id: { type: "string" },
			},
			required: ["name", "country_id", "session_id"],
			returns: {
				user_id: { type: "string" },
				slot: { type: "integer" },
				x: { type: "integer" },
				y: { type: "integer" },
			},
		},
		player_move: {
			params: {
				direction: {
					type: "string",
					enum: ["idle", "up", "down", "left", "right"],
				},
				seq: { type: "integer" },
			},
			required: ["direction", "seq"],
			returns: null,
		},
	},
	presence: {
		user: {
			status: { type: "string", enum: ["active", "idle"] },
			name: { type: "string" },
		},
		shared: { slide: { type: "integer" } },
	},
};

function generateSample(): string {
	return generateTypes(
		sampleSchema.store,
		sampleSchema.actions,
		sampleSchema.presence,
	);
}

describe("generateTypes", () => {
	test("emits required, optional, nested, bytes, array, and enum fields", () => {
		const output = generateSample();

		expect(output).toContain("export type ZyncBaseSchema = {");
		expect(output).toContain(
			'import type { JsonValue } from "@zyncbase/client";',
		);
		expect(output).toContain("color_indexes: Uint8Array;");
		expect(output).toContain("tags?: JsonValue[];");
		expect(output).toContain('role?: "admin" | "player";');
		expect(output).toContain("label: string;");
		expect(output).toContain("name?: string;");
		expect(output).toContain("handle?: string;");
		expect(output).toContain("city?: string;");
		expect(output).not.toContain("ValidPaths");
	});

	test("emits typed actions with enums and void returns", () => {
		const output = generateSample();

		expect(output).toContain("export type ZyncBaseActions = {");
		expect(output).toContain("name: string;");
		expect(output).toContain(
			'direction: "idle" | "up" | "down" | "left" | "right";',
		);
		expect(output).toContain("returns: undefined;");
		expect(output).toContain("user_id: string;");
	});

	test("emits typed presence scopes", () => {
		const output = generateSample();

		expect(output).toContain("export type ZyncBasePresence = {");
		expect(output).toContain('status?: "active" | "idle";');
		expect(output).toContain("slide?: number;");
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

	test("rejects invalid action and presence declarations", () => {
		const badParam: SchemaFile = {
			version: "1.0.0",
			store: {},
			actions: {
				move: {
					params: { seq: { type: "integer" } },
					required: ["missing"],
				},
			},
		};
		expect(validateSchema(badParam)).toContain(
			'requires unknown param "missing"',
		);

		const badEnum = {
			version: "1.0.0",
			store: {},
			presence: {
				user: { status: { type: "string", enum: [{ nope: true }] } },
			},
		} as unknown as SchemaFile;
		expect(validateSchema(badEnum)).toContain("invalid enum");
	});

	test("rejects a missing version", () => {
		const schema = { store: {} } as SchemaFile;
		expect(validateSchema(schema)).toContain('non-empty "version"');
	});
});

describe("generated schema compiles against the typed API", () => {
	test("generated types drive store, query, action, and presence typing", () => {
		const typesContent = generateSample();

		const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "zyncbase-cli-"));
		const typesFile = path.join(tmpDir, "zync-types.ts");
		const consumerFile = path.join(tmpDir, "consumer.ts");
		const sdkTypes = path
			.resolve(import.meta.dir, "../src/types.ts")
			.replace(/\\/g, "/");

		const consumer = `import type { Actions, Presence, Store } from "@zyncbase/client";
import type {
	ZyncBaseActions,
	ZyncBasePresence,
	ZyncBaseSchema,
} from "./zync-types";

declare const store: Store<ZyncBaseSchema>;
declare const actions: Actions<ZyncBaseActions>;
declare const presence: Presence<ZyncBasePresence>;

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

await store.query("chunks", {
	where: { label: { contains: "a" }, "meta.created": { gte: 1 } },
	orderBy: [{ label: "asc" }],
	limit: 10,
});
// @ts-expect-error unknown where field
await store.query("chunks", { where: { nope: 1 } });
// @ts-expect-error comparison on a bytes field
await store.query("chunks", { where: { color_indexes: { gte: 1 } } });
// @ts-expect-error orderBy clause must name exactly one field
await store.query("chunks", { orderBy: [{ label: "asc", meta: "desc" }] });

const joined = await actions.call("player_join", {
	name: "a",
	country_id: 1,
	session_id: "s",
});
const userId: string = joined.user_id;
await actions.call("player_move", { direction: "up", seq: 1 });
// @ts-expect-error invalid enum value
await actions.call("player_move", { direction: "sideways", seq: 1 });
// @ts-expect-error unknown action
await actions.call("nope");

await presence.set({ status: "active" });
// @ts-expect-error invalid presence enum value
await presence.set({ status: "busy" });

void name;
void bytes;
void city;
void id;
void userId;
`;

		try {
			Bun.write(typesFile, typesContent);
			Bun.write(consumerFile, consumer);
			const tsconfigFile = path.join(tmpDir, "tsconfig.json");
			Bun.write(
				tsconfigFile,
				JSON.stringify({
					compilerOptions: {
						noEmit: true,
						strict: true,
						target: "ESNext",
						module: "ESNext",
						moduleResolution: "bundler",
						skipLibCheck: true,
						allowImportingTsExtensions: true,
						baseUrl: ".",
						paths: { "@zyncbase/client": [sdkTypes] },
					},
					include: ["consumer.ts"],
				}),
			);

			const tscPath = new URL("../node_modules/.bin/tsc", import.meta.url)
				.pathname;
			const result = Bun.spawnSync([tscPath, "-p", tsconfigFile]);

			if (result.exitCode !== 0) console.log(result.stdout.toString());
			expect(result.stderr.toString()).toBe("");
			expect(result.exitCode).toBe(0);
		} finally {
			fs.rmSync(tmpDir, { recursive: true, force: true });
		}
	});
});
