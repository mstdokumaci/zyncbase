// Micro-benchmark for the shared viewport data plane. Run:
//   bun examples/cordon-off/viewport.perf.ts
// Report-only; no assertions. Simulates one farm worker's worth of peers and
// isolates the hot paths the farm amplifies (frames, own-dot receives,
// direction rotations, and the shared decode paths).
import type { AppClient } from "./shared";
import {
	encodeColorIndexes,
	encodeCoordinates,
	findCoordinate,
	readColorIndexes,
	readCoordinates,
} from "./shared";
import { FRAME_MS, ViewSession } from "./viewport";

const PEERS = 64;
const TICK_MS = 50;
const TICKS = 6000; // 5 simulated minutes at 20 Hz
const DIRECTIONS = ["right", "down", "left", "up"] as const;
const TARGET_SLOT = 7;
let sink = 0;

type PeerDot = { slot: number; x: number; y: number; colorIndex: number };

type FakeStore = {
	listen: () => Promise<{ unlisten: () => Promise<void> }>;
	reads: number;
};

function makeStore(): FakeStore {
	return {
		reads: 0,
		listen() {
			this.reads++;
			return Promise.resolve({ unlisten: () => Promise.resolve() });
		},
	};
}

function makeSession(store: FakeStore) {
	return new ViewSession({
		store: () => store as unknown as AppClient["store"],
		sinks: { country: { receive: () => {} }, user: { receive: () => {} } },
		width: 1440,
		height: 900,
		scale: 8,
		land: new Uint8Array(2000 * 1000),
		ownerAt: () => 0,
		isOnline: () => true,
		client: () => undefined,
	});
}

function makeSessions(): {
	sessions: ViewSession[];
	dots: PeerDot[];
} {
	const dots = Array.from({ length: PEERS }, (_, index) => ({
		slot: index + 1,
		x: 200 + (index % 16) * 40,
		y: 200 + Math.floor(index / 16) * 40,
		colorIndex: 0,
	}));
	const sessions = dots.map(() => makeSession(makeStore()));
	return { sessions, dots };
}

function report(
	label: string,
	start: { user: number; system: number },
	elapsedMs: number,
	ops: number,
) {
	const cpu = process.cpuUsage(start);
	const cpuMs = (cpu.user + cpu.system) / 1000;
	console.log(
		`${label.padEnd(18)} wall ${elapsedMs.toFixed(0).padStart(5)} ms  cpu ${cpuMs
			.toFixed(0)
			.padStart(
				5,
			)} ms  ${((elapsedMs / ops) * 1e6).toFixed(0).padStart(6)} ns/op  (${ops} ops)`,
	);
}

function benchOne(label: string, rounds: number, run: (i: number) => void) {
	const start = process.cpuUsage();
	const t0 = performance.now();
	for (let i = 0; i < rounds; i++) run(i);
	report(label, start, performance.now() - t0, rounds);
}

function stepDot(
	dot: { x: number; y: number },
	step: (typeof DIRECTIONS)[number],
) {
	if (step === "right") dot.x = (dot.x + 1) % 2000;
	else if (step === "left") dot.x = (dot.x + 1999) % 2000;
	else if (step === "down") dot.y = (dot.y + 1) % 1000;
	else dot.y = (dot.y + 999) % 1000;
}

function benchFrames() {
	const { sessions, dots } = makeSessions();
	for (const [i, session] of sessions.entries()) session.admit(dots[i]);
	for (const [i, session] of sessions.entries())
		session.receiveSelf(dots[i], 0);
	const start = process.cpuUsage();
	const t0 = performance.now();
	let ops = 0;
	let now = 0;
	for (let tick = 0; tick < TICKS; tick++) {
		now += TICK_MS;
		for (const session of sessions) {
			session.frame(now);
			ops++;
		}
	}
	report("frames", start, performance.now() - t0, ops);
}

function benchMixed() {
	const { sessions, dots } = makeSessions();
	for (const [i, session] of sessions.entries()) session.admit(dots[i]);
	const start = process.cpuUsage();
	const t0 = performance.now();
	const state = { nextFrame: 0, direction: 0, ops: 0 };
	simulate(sessions, dots, state);
	report("mixed", start, performance.now() - t0, state.ops);
}

type MixedState = { nextFrame: number; direction: number; ops: number };

function pumpFrames(sessions: ViewSession[], state: MixedState, now: number) {
	while (state.nextFrame <= now) {
		for (const session of sessions) session.frame(state.nextFrame);
		state.nextFrame += FRAME_MS;
		state.ops += sessions.length;
	}
}

function movePeers(
	sessions: ViewSession[],
	dots: PeerDot[],
	state: MixedState,
	now: number,
) {
	for (const [i, session] of sessions.entries()) {
		stepDot(dots[i], DIRECTIONS[(state.direction + i) % 4]);
		session.receiveSelf(dots[i], now);
		state.ops++;
	}
}

function rotate(sessions: ViewSession[], state: MixedState, tick: number) {
	if (tick % 80 !== 0) return;
	state.direction++;
	for (const [i, session] of sessions.entries())
		session.setDirection(DIRECTIONS[(state.direction + i) % 4]);
	state.ops += sessions.length;
}

function simulate(sessions: ViewSession[], dots: PeerDot[], state: MixedState) {
	for (let tick = 0; tick < TICKS; tick++) {
		const now = tick * TICK_MS;
		pumpFrames(sessions, state, now);
		movePeers(sessions, dots, state, now);
		rotate(sessions, state, tick);
	}
}

function benchRotations() {
	const { sessions, dots } = makeSessions();
	for (const [i, session] of sessions.entries()) session.admit(dots[i]);
	const rounds = 200_000;
	benchOne("rotations", rounds, (i) => {
		const session = sessions[i % sessions.length];
		// Every visit changes that session's direction, so the update path runs.
		session.setDirection(DIRECTIONS[(i + Math.floor(i / PEERS)) % 4]);
	});
}

function benchCoordinates() {
	const dots = Array.from({ length: 12 }, (_, i) => ({
		slot: i + 1,
		x: 10 + i * 3,
		y: 5 + i,
	}));
	const bytes = encodeCoordinates(0, dots);
	const session = makeSession(makeStore());
	session.admit({ x: 10, y: 5 });
	const rounds = 1_000_000;

	benchOne("readCoordinates", rounds, () => {
		const found = readCoordinates(bytes).find((d) => d.slot === TARGET_SLOT);
		if (found) sink += found.x;
	});
	benchOne("findCoordinate", rounds, () => {
		const found = findCoordinate(bytes, TARGET_SLOT);
		if (found) sink += found.x;
	});
	benchOne("farm-path-old", rounds, (i) => {
		const found = readCoordinates(bytes).find((d) => d.slot === TARGET_SLOT);
		if (found) session.receiveSelf({ ...found, colorIndex: 0 }, i * TICK_MS);
	});
	benchOne("farm-path-new", rounds, (i) => {
		const found = findCoordinate(bytes, TARGET_SLOT);
		if (found) session.receiveSelf({ ...found, colorIndex: 0 }, i * TICK_MS);
	});
}

function benchCountryDecode() {
	const cells = new Uint8Array(50 * 25);
	for (let i = 0; i < cells.length; i++) cells[i] = i % 7;
	const bytes = encodeColorIndexes(cells);
	benchOne("country-decode", 200_000, () => {
		sink += readColorIndexes(bytes).length;
	});
}

// Decode variants for readColorIndexes: short-run chunks (busy borders) made
// the old fill()-per-run cost dominant; keep the comparison in-tree.
function benchDecodeVariants() {
	const cells = new Uint8Array(50 * 25);
	for (let i = 0; i < cells.length; i++) cells[i] = i % 7;
	const bytes = encodeColorIndexes(cells);
	const decodeManual = (encoded: Uint8Array) => {
		const codes = new Uint8Array(50 * 25);
		let out = 0;
		for (let i = 0; i < encoded.length; i += 2) {
			const run = encoded[i];
			const code = encoded[i + 1];
			for (let k = 0; k < run; k++) codes[out++] = code;
		}
		return codes;
	};
	const decodeFastPath = (encoded: Uint8Array) => {
		const codes = new Uint8Array(50 * 25);
		let out = 0;
		for (let i = 0; i < encoded.length; i += 2) {
			const run = encoded[i];
			const code = encoded[i + 1];
			if (run === 1) codes[out++] = code;
			else {
				codes.fill(code, out, out + run);
				out += run;
			}
		}
		return codes;
	};
	benchOne("decode-current", 200_000, () => {
		sink += readColorIndexes(bytes).length;
	});
	benchOne("decode-manual", 200_000, () => {
		sink += decodeManual(bytes).length;
	});
	benchOne("decode-fastpath", 200_000, () => {
		sink += decodeFastPath(bytes).length;
	});
}

benchFrames();
benchMixed();
benchRotations();
benchCoordinates();
benchCountryDecode();
benchDecodeVariants();
if (sink < 0) throw new Error("unreachable");
