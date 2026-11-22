import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import { parseArgs } from "node:util";

// Attribute a Bun --cpu-prof profile to the measured phases by walking stacks.
// Chrome's own report mixes fixture setup, verification, and the tick loop.

type CallFrame = {
	functionName?: string;
	lineNumber?: number;
	url?: string;
};
type ProfileNode = { callFrame: CallFrame; children?: number[]; id: number };
type Profile = {
	samples: number[];
	nodes: ProfileNode[];
	startTime: number;
	endTime: number;
};
type Tally = { key: string; location: string; self: number; total: number };
type PhaseReport = {
	samples: number;
	self: Tally[];
	inclusive: Tally[];
};
type Report = {
	label: string;
	durationMs: number;
	intervalMs: number;
	phases: Record<string, PhaseReport>;
	coverage: { simulationMs?: number; serializationMs?: number };
};

const { values, positionals } = parseArgs({
	args: process.argv.slice(2),
	allowPositionals: true,
	options: {
		json: { type: "string" },
		top: { type: "string", default: "12" },
	},
});
const top = Number(values.top);
const paths = positionals.flatMap((path) =>
	statSync(path).isDirectory() ? profilesIn(path) : [path],
);
if (!paths.length) throw new Error("No .cpuprofile files found");

function profilesIn(dir: string): string[] {
	return readdirSync(dir, { recursive: true, encoding: "utf8" })
		.filter((file) => file.endsWith(".cpuprofile"))
		.map((file) => join(dir, file));
}

/** Groups JIT tiers of one function: name plus source file, ignore line. */
function keyOf(node: ProfileNode): { key: string; location: string } {
	const name = node.callFrame.functionName || "(anonymous)";
	const url = node.callFrame.url || "";
	const file = url ? basename(url) : "native";
	return {
		key: `${name}@${file}`,
		location: `${file}:${(node.callFrame.lineNumber ?? -1) + 1}`,
	};
}

/** Bucket by the harness frame the sample sits under. */
function phaseOf(chain: ProfileNode[]): string {
	const has = (name: string, file: string) =>
		chain.some(
			(node) =>
				node.callFrame.functionName === name &&
				(node.callFrame.url || "").endsWith(file),
		);
	if (!has("measure", "profile.ts")) {
		if (has("fixture", "profile.ts") || has("paint", "profile.ts"))
			return "fixture";
		if (has("verify", "profile.ts")) return "verify";
		return "other";
	}
	if (has("tick", "world.ts")) return "tick";
	if (has("changes", "profile.ts")) return "changes";
	if (has("steer", "profile.ts")) return "steer";
	return "loop";
}

/** Every node from a sample up to the root, leaf first. */
function ancestorsOf(
	start: number,
	byId: Map<number, ProfileNode>,
	parent: Map<number, number>,
): ProfileNode[] {
	const chain: ProfileNode[] = [];
	for (
		let at: number | undefined = start;
		at !== undefined;
		at = parent.get(at)
	) {
		const node = byId.get(at);
		if (!node) break;
		chain.push(node);
	}
	return chain;
}

/** Count one sample as leaf self time and as inclusive time for every ancestor. */
function tallySample(
	chain: ProfileNode[],
	self: Map<string, Tally>,
	inclusive: Map<string, Tally>,
): void {
	const seen = new Set<string>();
	for (const node of chain) {
		const { key, location } = keyOf(node);
		if (seen.has(key)) continue;
		seen.add(key);
		const entry = inclusive.get(key) ?? { key, location, self: 0, total: 0 };
		entry.total++;
		inclusive.set(key, entry);
	}
	const leaf = keyOf(chain[0]);
	const entry = self.get(leaf.key) ?? {
		key: leaf.key,
		location: leaf.location,
		self: 0,
		total: 0,
	};
	entry.self++;
	self.set(leaf.key, entry);
}

function analyze(path: string): Report {
	const profile = JSON.parse(readFileSync(path, "utf8")) as Profile;
	const byId = new Map(profile.nodes.map((node) => [node.id, node]));
	const parent = new Map<number, number>();
	for (const node of profile.nodes)
		for (const child of node.children ?? []) parent.set(child, node.id);
	const phaseTallies = new Map<
		string,
		{ self: Map<string, Tally>; inclusive: Map<string, Tally> }
	>();
	for (const id of profile.samples) {
		const chain = ancestorsOf(id, byId, parent);
		if (!chain.length) continue;
		const phase = phaseOf(chain);
		let tallies = phaseTallies.get(phase);
		if (!tallies) {
			tallies = { self: new Map(), inclusive: new Map() };
			phaseTallies.set(phase, tallies);
		}
		tallySample(chain, tallies.self, tallies.inclusive);
	}
	const phases: Record<string, PhaseReport> = {};
	for (const [phase, tallies] of phaseTallies) {
		phases[phase] = {
			samples: [...tallies.self.values()].reduce((sum, t) => sum + t.self, 0),
			self: [...tallies.self.values()].sort((a, b) => b.self - a.self),
			inclusive: [...tallies.inclusive.values()].sort(
				(a, b) => b.total - a.total,
			),
		};
	}
	return {
		label: `${basename(join(path, "..", ".."))}/${basename(join(path, ".."))}`,
		durationMs: (profile.endTime - profile.startTime) / 1000,
		intervalMs:
			(profile.endTime - profile.startTime) / 1000 / profile.samples.length,
		phases,
		coverage: reportedTotals(path),
	};
}

/** Sibling harness artifact, when the run wrote one, for phase coverage. */
function reportedTotals(path: string) {
	const out = join(path, "..", "out");
	try {
		const file = readdirSync(out).find((name) => name.endsWith(".json"));
		if (!file) return {};
		const result = JSON.parse(readFileSync(join(out, file), "utf8"));
		return {
			simulationMs: result.simulation?.totalMs as number | undefined,
			serializationMs: result.serialization?.totalMs as number | undefined,
		};
	} catch {
		return {};
	}
}

function printReport(report: Report) {
	console.log(
		`\n=== ${report.label} — ${report.durationMs.toFixed(0)} ms, ${report.phases ? Object.values(report.phases).reduce((sum, p) => sum + p.samples, 0) : 0} samples, ${report.intervalMs.toFixed(3)} ms each`,
	);
	const coverage = report.coverage;
	if (coverage.simulationMs || coverage.serializationMs)
		console.log(
			`reported: simulation ${coverage.simulationMs?.toFixed(0)} ms, serialization ${coverage.serializationMs?.toFixed(0)} ms`,
		);
	for (const [name, phase] of Object.entries(report.phases).sort(
		(a, b) => b[1].samples - a[1].samples,
	)) {
		const ms = phase.samples * report.intervalMs;
		console.log(`\n-- ${name}: ${phase.samples} samples (${ms.toFixed(0)} ms)`);
		console.log("   self:");
		for (const tally of phase.self.slice(0, top))
			console.log(
				`   ${((100 * tally.self) / phase.samples).toFixed(1).padStart(5)}% ${(tally.self * report.intervalMs).toFixed(1).padStart(8)} ms  ${tally.key}  ${tally.location}`,
			);
		console.log("   inclusive:");
		for (const tally of phase.inclusive.slice(0, top))
			console.log(
				`   ${((100 * tally.total) / phase.samples).toFixed(1).padStart(5)}% ${(tally.total * report.intervalMs).toFixed(1).padStart(8)} ms  ${tally.key}`,
			);
	}
}

const reports = paths.map(analyze);
for (const report of reports) printReport(report);
if (values.json) writeFileSync(values.json, JSON.stringify(reports, null, 2));
