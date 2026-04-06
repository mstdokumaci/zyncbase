import { describe, expect, setDefaultTimeout, test } from "bun:test";

// tsc spawns are slow — give the compile test plenty of time
setDefaultTimeout(120_000);

import * as os from "node:os";
import * as path from "node:path";
import * as fc from "fast-check";

import {
	collectFieldPathsForTest,
	emitValidPathsForTest,
	generateTypesForTest,
	type SchemaField,
} from "./generate";

// ─── Arbitraries ──────────────────────────────────────────────────────────────

/** Generate a valid field name (no __, no dots, non-empty) */
const validFieldName = fc
	.string({ minLength: 1, maxLength: 20 })
	.filter(
		(s) =>
			!s.includes("__") &&
			!s.includes(".") &&
			/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(s),
	);

/** Generate a leaf SchemaField (non-object) */
const leafField = fc.oneof(
	fc.constant({ type: "string" as const }),
	fc.constant({ type: "integer" as const }),
	fc.constant({ type: "number" as const }),
	fc.constant({ type: "boolean" as const }),
	fc.constant({ type: "array" as const }),
);

/** Generate a SchemaField with optional nesting up to depth 2 */
const schemaField: fc.Arbitrary<SchemaField> = fc.oneof(
	{ weight: 3, arbitrary: leafField },
	{
		weight: 1,
		arbitrary: fc.record({
			type: fc.constant("object" as const),
			fields: fc.dictionary(validFieldName, leafField, {
				minKeys: 1,
				maxKeys: 4,
			}),
		}),
	},
);

/** Generate a SchemaCollection */
const schemaCollection = fc.record({
	fields: fc.dictionary(validFieldName, schemaField, {
		minKeys: 1,
		maxKeys: 5,
	}),
	required: fc.option(
		fc.array(validFieldName, { minLength: 0, maxLength: 3 }),
		{ nil: undefined },
	),
});

/** Generate a SchemaFile */
const schemaFileArb = fc.record({
	version: fc.constant("1"),
	store: fc.dictionary(validFieldName, schemaCollection, {
		minKeys: 1,
		maxKeys: 4,
	}),
});

// ─── Property 13: CLI ValidPaths completeness ─────────────────────────────────

/**
 * Property 13: CLI ValidPaths completeness
 * Validates: Requirements 11.3
 *
 * For any valid SchemaFile, the generated ValidPaths union SHALL contain a tuple
 * entry for every valid path derivable from the schema.
 */
describe("CLI ValidPaths completeness", () => {
	test("Property 13: ValidPaths contains a tuple for every derivable path", () => {
		fc.assert(
			fc.property(schemaFileArb, (schemaFile) => {
				const validPathsOutput = emitValidPathsForTest(schemaFile.store);

				for (const [collectionName, collection] of Object.entries(
					schemaFile.store,
				)) {
					// Every collection must have a [collection, string] tuple
					expect(validPathsOutput).toContain(`["${collectionName}", string]`);

					// Every field path must appear
					const fieldPaths = collectFieldPathsForTest(collection.fields, 1, 3);
					for (const fieldPath of fieldPaths) {
						const segments = [
							`"${collectionName}"`,
							"string",
							...fieldPath.map((f) => `"${f}"`),
						];
						const tuple = `[${segments.join(", ")}]`;
						expect(validPathsOutput).toContain(tuple);
					}
				}
			}),
			{ numRuns: 100 },
		);
	});
});

// ─── Property 12: CLI schema-to-types round-trip compile ─────────────────────

/**
 * Property 12: CLI schema-to-types round-trip compile
 * Validates: Requirements 11.9
 *
 * For any valid SchemaFile, generating types and running tsc --noEmit on an
 * importing file SHALL exit with code 0.
 */
describe("CLI schema-to-types round-trip compile", () => {
	test("Property 12: generated types compile without errors", () => {
		fc.assert(
			fc.property(schemaFileArb, (schemaFile) => {
				// Generate the types content
				const typesContent = generateTypesForTest(schemaFile.store);

				// Write to a temp file
				const tmpDir = os.tmpdir();
				const typesFile = path.join(
					tmpDir,
					`zyncbase-types-${Date.now()}-${Math.random().toString(36).slice(2)}.ts`,
				);
				const importFile = path.join(
					tmpDir,
					`zyncbase-import-${Date.now()}-${Math.random().toString(36).slice(2)}.ts`,
				);

				// Write types file
				Bun.write(typesFile, typesContent);

				// Write a file that imports and uses the types
				const importContent = `import type { ZyncBaseSchema, ValidCollections, ValidPaths } from "${typesFile.replace(/\\/g, "/")}";
// Use the types to ensure they are valid
type _Schema = ZyncBaseSchema;
type _Collections = ValidCollections;
type _Paths = ValidPaths;
`;
				Bun.write(importFile, importContent);

				// Run tsc --noEmit using the local tsc binary
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
					"--allowImportingTsExtensions",
					importFile,
				]);

				// Clean up
				try {
					Bun.file(typesFile);
					Bun.file(importFile);
				} catch {}

				expect(result.exitCode).toBe(0);
			}),
			{ numRuns: 5 }, // fewer runs since each spawns a tsc process (~1-2s each)
		);
	});
});
