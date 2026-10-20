#!/usr/bin/env bun
// CLI type generator (Bun-only).
// Usage: bunx @zyncbase/client generate --schema <path> --out <path> [--check] [--watch]
//
// Emits a single `ZyncBaseSchema` interface. Path and value types are derived
// from it by `createClient<ZyncBaseSchema>(...)` — nothing else is generated.

import { watch as fsWatch } from "node:fs";
import { basename, dirname } from "node:path";

interface SchemaField {
	type:
		| "string"
		| "integer"
		| "number"
		| "boolean"
		| "array"
		| "bytes"
		| "object";
	fields?: Record<string, SchemaField>;
}

interface SchemaCollection {
	fields: Record<string, SchemaField>;
	required?: string[];
	unique?: string[][];
}

interface SchemaFile {
	version: string;
	store: Record<string, SchemaCollection>;
}

interface Args {
	schema: string;
	out: string;
	check: boolean;
	watch: boolean;
}

// ─── Argument parsing ─────────────────────────────────────────────────────────

function parseArgs(argv: string[]): Args | null {
	let schema: string | null = null;
	let out: string | null = null;
	let check = false;
	let watch = false;

	for (let i = 0; i < argv.length; i++) {
		const arg = argv[i];
		if (arg === "--schema" && i + 1 < argv.length) {
			schema = argv[++i];
		} else if (arg === "--out" && i + 1 < argv.length) {
			out = argv[++i];
		} else if (arg === "--check") {
			check = true;
		} else if (arg === "--watch") {
			watch = true;
		}
	}

	if (!schema || !out) return null;
	return { schema, out, check, watch };
}

// ─── Validation ───────────────────────────────────────────────────────────────

const TS_TYPE_MAP: Record<Exclude<SchemaField["type"], "object">, string> = {
	string: "string",
	integer: "number",
	number: "number",
	boolean: "boolean",
	array: "unknown[]",
	bytes: "Uint8Array",
};

// schema-grammar.md: identifiers must match [A-Za-z][A-Za-z0-9_]*
const IDENTIFIER = /^[A-Za-z][A-Za-z0-9_]*$/;

export function validateSchema(schemaData: SchemaFile): string | null {
	if (typeof schemaData.version !== "string" || schemaData.version === "") {
		return 'Schema file is missing a non-empty "version".';
	}
	if (!schemaData.store || typeof schemaData.store !== "object") {
		return 'Schema file is missing the "store" collection map.';
	}

	for (const [collectionName, collection] of Object.entries(schemaData.store)) {
		const error = validateCollection(collectionName, collection);
		if (error) return error;
	}

	return null;
}

function validateCollection(
	collectionName: string,
	collection: SchemaCollection,
): string | null {
	const nameError = validateIdentifier(collectionName, "collection");
	if (nameError) return nameError;
	if (!collection?.fields || typeof collection.fields !== "object") {
		return `Collection "${collectionName}" is missing "fields".`;
	}

	const fieldError = validateFields(collection.fields, collectionName);
	if (fieldError) return fieldError;

	for (const required of collection.required ?? []) {
		if (!(required in collection.fields)) {
			return `Collection "${collectionName}" requires unknown field "${required}".`;
		}
	}

	for (const uniquePath of collection.unique ?? []) {
		if (!resolveFieldPath(collection.fields, uniquePath)) {
			return `Collection "${collectionName}" has a unique constraint on unknown field path "${uniquePath.join(".")}".`;
		}
	}

	return null;
}

function validateFields(
	fields: Record<string, SchemaField>,
	context: string,
): string | null {
	for (const [fieldName, field] of Object.entries(fields)) {
		const nameError = validateIdentifier(fieldName, `field in "${context}"`);
		if (nameError) return nameError;

		if (field.type === "object") {
			if (field.fields) {
				const error = validateFields(field.fields, `${context}.${fieldName}`);
				if (error) return error;
			}
		} else if (!(field.type in TS_TYPE_MAP)) {
			return `Field "${context}.${fieldName}" has unsupported type "${field.type}".`;
		}
	}
	return null;
}

function validateIdentifier(name: string, kind: string): string | null {
	if (name.includes("__")) {
		return `Field name "${name}" in ${kind} contains "__", the reserved flattening separator.`;
	}
	if (!IDENTIFIER.test(name)) {
		return `Invalid ${kind} name "${name}": must match [A-Za-z][A-Za-z0-9_]*.`;
	}
	return null;
}

/** Walks a constraint path through nested object fields; must end on a leaf. */
function resolveFieldPath(
	fields: Record<string, SchemaField>,
	path: string[],
): boolean {
	let current: Record<string, SchemaField> | undefined = fields;
	for (let i = 0; i < path.length; i++) {
		const field = current?.[path[i]];
		if (!field) return false;
		if (i === path.length - 1) return field.type !== "object";
		if (field.type !== "object" || !field.fields) return false;
		current = field.fields;
	}
	return false;
}

// ─── Type emitter ─────────────────────────────────────────────────────────────

function emitFieldType(field: SchemaField, indent: string): string {
	if (field.type === "object") {
		if (!field.fields || Object.keys(field.fields).length === 0) {
			return "Record<string, unknown>";
		}
		return emitObject(field.fields, indent);
	}
	return TS_TYPE_MAP[field.type] ?? "unknown";
}

/** Nested objects carry no required metadata — their members are optional. */
function emitObject(
	fields: Record<string, SchemaField>,
	indent: string,
): string {
	const innerIndent = `${indent}\t`;
	const lines: string[] = ["{"];
	for (const [fieldName, field] of Object.entries(fields)) {
		lines.push(
			`${innerIndent}${fieldName}?: ${emitFieldType(field, innerIndent)};`,
		);
	}
	lines.push(`${indent}}`);
	return lines.join("\n");
}

function emitZyncBaseSchema(store: Record<string, SchemaCollection>): string {
	// A type alias (not interface): only aliases get the implicit index
	// signature that keeps a typed client assignable to the loose fallback.
	const lines: string[] = ["export type ZyncBaseSchema = {"];
	for (const [collectionName, collection] of Object.entries(store)) {
		const requiredSet = new Set(collection.required ?? []);
		lines.push(`\t${collectionName}: {`);
		for (const [fieldName, field] of Object.entries(collection.fields)) {
			const optMark = requiredSet.has(fieldName) ? "" : "?";
			lines.push(
				`\t\t${fieldName}${optMark}: ${emitFieldType(field, "\t\t")};`,
			);
		}
		lines.push("\t};");
	}
	lines.push("};");
	return lines.join("\n");
}

/**
 * Generate the full types output for a store.
 */
export function generateTypes(store: Record<string, SchemaCollection>): string {
	return [
		"// Auto-generated by bunx @zyncbase/client generate. Do not edit manually.",
		"",
		emitZyncBaseSchema(store),
		"",
	].join("\n");
}

export type { SchemaCollection, SchemaField, SchemaFile };

// ─── Main ─────────────────────────────────────────────────────────────────────

async function loadAndGenerate(
	schemaPath: string,
): Promise<{ ok: true; content: string } | { ok: false; error: string }> {
	const schemaFile = Bun.file(schemaPath);
	if (!(await schemaFile.exists())) {
		return { ok: false, error: `Schema file not found: ${schemaPath}` };
	}

	let schemaData: SchemaFile;
	try {
		schemaData = JSON.parse(await schemaFile.text()) as SchemaFile;
	} catch {
		return { ok: false, error: `Invalid JSON in schema file: ${schemaPath}` };
	}

	const validationError = validateSchema(schemaData);
	if (validationError) return { ok: false, error: validationError };

	return { ok: true, content: generateTypes(schemaData.store) };
}

function watchSchema(args: Args): void {
	const target = basename(args.schema);
	let timer: ReturnType<typeof setTimeout> | null = null;

	// Watch the directory: editors that save via rename replace the inode.
	fsWatch(dirname(args.schema), (_event, filename) => {
		if (filename !== null && filename !== target) return;
		if (timer) clearTimeout(timer);
		timer = setTimeout(async () => {
			const result = await loadAndGenerate(args.schema);
			if (!result.ok) {
				process.stderr.write(`Error: ${result.error}\n`);
				return;
			}
			await Bun.write(args.out, result.content);
			process.stdout.write(`Regenerated ${args.out}\n`);
		}, 50);
	});

	process.stdout.write(`Watching ${args.schema} for changes...\n`);
}

export async function generate(argv: string[]): Promise<void> {
	const args = parseArgs(argv);
	if (!args) {
		process.stderr.write(
			"Usage: bunx @zyncbase/client generate --schema <path> --out <path> [--check] [--watch]\n",
		);
		process.exit(1);
	}

	const result = await loadAndGenerate(args.schema);
	if (!result.ok) {
		process.stderr.write(`Error: ${result.error}\n`);
		process.exit(1);
	}

	if (args.check) {
		const current = Bun.file(args.out);
		const upToDate =
			(await current.exists()) && (await current.text()) === result.content;
		if (!upToDate) {
			process.stderr.write(
				`Error: ${args.out} is out of date. Run: bunx @zyncbase/client generate --schema ${args.schema} --out ${args.out}\n`,
			);
			process.exit(1);
		}
		process.stdout.write(`${args.out} is up to date.\n`);
		return;
	}

	await Bun.write(args.out, result.content);
	process.stdout.write(`Generated ${args.out}\n`);

	if (args.watch) watchSchema(args);
}

// Run when invoked directly
if (import.meta.main) {
	await generate(process.argv.slice(2));
}
