#!/usr/bin/env bun
// CLI type generator (Bun-only).
// Usage: bunx @zyncbase/client generate --schema <path> --out <path> [--check] [--watch]
//
// Emits `ZyncBaseSchema` (store), `ZyncBaseActions`, and `ZyncBasePresence`.
// Path, query, action, and presence types are derived from these aliases by
// `createClient<ZyncBaseSchema, ZyncBaseActions, ZyncBasePresence>(...)`.

import { watch as fsWatch } from "node:fs";
import { basename, dirname } from "node:path";

type EnumValue = string | number | boolean;

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
	enum?: EnumValue[];
}

interface SchemaCollection {
	fields: Record<string, SchemaField>;
	required?: string[];
	unique?: string[][];
}

interface SchemaAction {
	params?: Record<string, SchemaField>;
	required?: string[];
	returns?: Record<string, SchemaField> | null;
}

interface SchemaPresence {
	user?: Record<string, SchemaField>;
	shared?: Record<string, SchemaField>;
}

interface SchemaFile {
	version: string;
	store: Record<string, SchemaCollection>;
	actions?: Record<string, SchemaAction>;
	presence?: SchemaPresence;
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
	array: "JsonValue[]",
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

	const actionError = validateActions(schemaData.actions);
	if (actionError) return actionError;

	return validatePresence(schemaData.presence);
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

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: mirrors the schema grammar field rules.
function validateFields(
	fields: Record<string, SchemaField>,
	context: string,
): string | null {
	for (const [fieldName, field] of Object.entries(fields)) {
		const nameError = validateIdentifier(fieldName, `field in "${context}"`);
		if (nameError) return nameError;

		if (field.enum !== undefined) {
			if (
				!Array.isArray(field.enum) ||
				!field.enum.every(
					(value) =>
						typeof value === "string" ||
						typeof value === "number" ||
						typeof value === "boolean",
				)
			) {
				return `Field "${context}.${fieldName}" has an invalid enum.`;
			}
		}

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

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: mirrors the schema grammar action rules.
function validateActions(
	actions: Record<string, SchemaAction> | undefined,
): string | null {
	if (!actions || typeof actions !== "object") return null;

	for (const [name, action] of Object.entries(actions)) {
		const nameError = validateIdentifier(name, "action");
		if (nameError) return nameError;

		const params = action.params ?? {};
		const paramsError = validateFields(params, `action ${name}.params`);
		if (paramsError) return paramsError;

		for (const required of action.required ?? []) {
			if (!(required in params)) {
				return `Action "${name}" requires unknown param "${required}".`;
			}
		}

		if (action.returns) {
			const returnsError = validateFields(
				action.returns,
				`action ${name}.returns`,
			);
			if (returnsError) return returnsError;
		}
	}

	return null;
}

function validatePresence(presence: SchemaPresence | undefined): string | null {
	if (!presence || typeof presence !== "object") return null;

	for (const scope of ["user", "shared"] as const) {
		const fields = presence[scope];
		if (!fields) continue;
		if (typeof fields !== "object") {
			return `Presence "${scope}" must be a field map.`;
		}
		const error = validateFields(fields, `presence.${scope}`);
		if (error) return error;
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
	if (field.enum && field.enum.length > 0) {
		return field.enum.map((value) => JSON.stringify(value)).join(" | ");
	}
	if (field.type === "object") {
		if (!field.fields || Object.keys(field.fields).length === 0) {
			return "Record<string, unknown>";
		}
		return emitObject(field.fields, indent);
	}
	return TS_TYPE_MAP[field.type] ?? "unknown";
}

/** Emits an object literal; members are optional unless listed in `required`. */
function emitObject(
	fields: Record<string, SchemaField>,
	indent: string,
	required: Set<string> = new Set(),
): string {
	const innerIndent = `${indent}\t`;
	const lines: string[] = ["{"];
	for (const [fieldName, field] of Object.entries(fields)) {
		const optMark = required.has(fieldName) ? "" : "?";
		lines.push(
			`${innerIndent}${fieldName}${optMark}: ${emitFieldType(field, innerIndent)};`,
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
		const required = new Set(collection.required ?? []);
		lines.push(
			`\t${collectionName}: ${emitObject(collection.fields, "\t", required)};`,
		);
	}
	lines.push("};");
	return lines.join("\n");
}

function emitActions(actions: Record<string, SchemaAction>): string {
	const lines: string[] = ["export type ZyncBaseActions = {"];
	for (const [name, action] of Object.entries(actions)) {
		// `returns: null` marks an async action: `call` resolves on admission.
		const returns = action.returns
			? emitObject(action.returns, "\t\t", new Set(Object.keys(action.returns)))
			: "undefined";
		const params =
			action.params && Object.keys(action.params).length > 0
				? emitObject(action.params, "\t\t", new Set(action.required ?? []))
				: "Record<string, never>";
		lines.push(`\t${name}: {`);
		lines.push(`\t\tparams: ${params};`);
		lines.push(`\t\treturns: ${returns};`);
		lines.push("\t};");
	}
	lines.push("};");
	return lines.join("\n");
}

function emitPresence(presence: SchemaPresence): string {
	const lines: string[] = ["export type ZyncBasePresence = {"];
	if (presence.user) {
		lines.push(`\tuser: ${emitObject(presence.user, "\t")};`);
	}
	if (presence.shared) {
		lines.push(`\tshared: ${emitObject(presence.shared, "\t")};`);
	}
	lines.push("};");
	return lines.join("\n");
}

function fieldsUseJsonValue(
	fields: Record<string, SchemaField> | undefined,
): boolean {
	if (!fields) return false;
	for (const field of Object.values(fields)) {
		if (field.type === "array") return true;
		if (field.type === "object" && fieldsUseJsonValue(field.fields)) {
			return true;
		}
	}
	return false;
}

function usesJsonValue(
	store: Record<string, SchemaCollection>,
	actions: Record<string, SchemaAction> | undefined,
	presence: SchemaPresence | undefined,
): boolean {
	if (
		Object.values(store).some((collection) =>
			fieldsUseJsonValue(collection.fields),
		)
	) {
		return true;
	}
	if (actions) {
		for (const action of Object.values(actions)) {
			if (
				fieldsUseJsonValue(action.params) ||
				fieldsUseJsonValue(action.returns ?? undefined)
			) {
				return true;
			}
		}
	}
	return (
		fieldsUseJsonValue(presence?.user) || fieldsUseJsonValue(presence?.shared)
	);
}

/**
 * Generate the full types output for a schema.
 */
export function generateTypes(
	store: Record<string, SchemaCollection>,
	actions?: Record<string, SchemaAction>,
	presence?: SchemaPresence,
): string {
	const parts: string[] = [
		"// Auto-generated by bunx @zyncbase/client generate. Do not edit manually.",
		"",
	];

	if (usesJsonValue(store, actions, presence)) {
		parts.push('import type { JsonValue } from "@zyncbase/client";', "");
	}

	parts.push(emitZyncBaseSchema(store), "");

	if (actions && Object.keys(actions).length > 0) {
		parts.push(emitActions(actions), "");
	}
	if (presence) {
		parts.push(emitPresence(presence), "");
	}

	return parts.join("\n");
}

export type {
	SchemaAction,
	SchemaCollection,
	SchemaField,
	SchemaFile,
	SchemaPresence,
};

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

	return {
		ok: true,
		content: generateTypes(
			schemaData.store,
			schemaData.actions,
			schemaData.presence,
		),
	};
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
