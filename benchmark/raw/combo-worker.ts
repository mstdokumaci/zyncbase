import { parseArgs } from "node:util";
import {
	frameType,
	fromBase64,
	loadComboCorpus,
	makeJwt,
	RawConnection,
	rebaseDocId,
	rebaseNamespace,
} from "./protocol";

const { values } = parseArgs({
	args: Bun.argv.slice(2),
	options: {
		port: { type: "string" },
		host: { type: "string", default: "127.0.0.1" },
		secret: { type: "string" },
		corpus: { type: "string" },
		process: { type: "string" },
		shard: { type: "string", default: "0" },
		clients: { type: "string", default: "2500" },
	},
});

const port = Number(values.port);
const host = values.host;
const secret = values.secret ?? "";
const corpusPath = values.corpus;
const processIndex = Number(values.process);
const shard = Number(values.shard);
const clientsPerProcess = Number(values.clients);

if (
	!Number.isInteger(port) ||
	!host ||
	!secret ||
	!corpusPath ||
	!Number.isInteger(processIndex) ||
	processIndex < 0 ||
	processIndex >= 4 ||
	!Number.isInteger(shard) ||
	shard < 0 ||
	clientsPerProcess !== 2500
) {
	throw new Error("combo worker: invalid arguments");
}

const corpus = loadComboCorpus(corpusPath);
const expectedSchema = fromBase64(corpus.schemaSync);
const table = processIndex % 2 === 0 ? "items" : "events";
const room = processIndex < 2 ? 0 : 1;
const storeNamespace =
	shard === 0
		? corpus.setup.storeNamespace
		: rebaseNamespace(corpus.setup.storeNamespace, `public-s${shard}`);
const presenceNamespace =
	shard === 0
		? corpus.setup.presenceNamespaces[String(room)]
		: rebaseNamespace(
				corpus.setup.presenceNamespaces[String(room)],
				`presence-combo-s${shard}-room-${room}`,
			);
const sharedFrames = corpus.presenceShared[String(room)];
const createFrames = Array.from({ length: 100 }, (_, index) => {
	const frame = corpus.storeCreates[`${processIndex}:${index}`];
	if (!frame) throw new Error(`missing create ${processIndex}:${index}`);
	return rebaseDocId(frame, shard);
});
const updateFrames = Array.from({ length: 100 }, (_, index) => {
	const frame = corpus.storeUpdates[`${processIndex}:${index}`];
	if (!frame) throw new Error(`missing update ${processIndex}:${index}`);
	return rebaseDocId(frame, shard);
});
const cpuStart = process.cpuUsage();

type Phase =
	| "store-create"
	| "store-update"
	| "presence-user"
	| "presence-shared"
	| "converge";

let connections: RawConnection[] = [];
const setupFail: Record<string, number> = {};

function noteSetup(stage: string, conn: RawConnection): void {
	if (frameType(conn.lastFrame) !== 0x00) {
		setupFail[stage] = (setupFail[stage] ?? 0) + 1;
	}
}

async function connectWithStoreScope(
	subject: string,
	countAcks: boolean,
): Promise<RawConnection> {
	let conn: RawConnection | null = null;
	try {
		conn = await RawConnection.open(
			host,
			port,
			makeJwt(secret, subject),
			expectedSchema,
			false,
			countAcks,
		);
		conn.sendBase64(storeNamespace);
		await conn.waitFor(2);
		noteSetup("store-namespace", conn);
		return conn;
	} catch (error) {
		conn?.close();
		throw error;
	}
}

async function connectLocal(localId: number): Promise<RawConnection> {
	const globalId = processIndex * clientsPerProcess + localId;
	const subject =
		shard === 0
			? `combo-stress-${globalId}`
			: `combo-stress-s${shard}-${globalId}`;
	let lastError: unknown;
	for (let attempt = 0; attempt < 3; attempt++) {
		try {
			return await connectWithStoreScope(
				subject,
				localId < 200, // creators/updaters need write acks
			);
		} catch (error) {
			lastError = error;
			if (attempt < 2) await Bun.sleep(50);
		}
	}
	if (lastError instanceof Error) throw lastError;
	throw new Error(String(lastError));
}

try {
	// Match the e2e connect phase: clients connect concurrently, store scope
	// handshake included, 250 in flight. Keep the localId index stable.
	connections = new Array<RawConnection>(clientsPerProcess);
	let next = 0;
	let failure: Error | null = null;
	const connector = async () => {
		while (failure === null) {
			const localId = next++;
			if (localId >= clientsPerProcess) return;
			try {
				connections[localId] = await connectLocal(localId);
			} catch (error) {
				const reason = error instanceof Error ? error.message : String(error);
				failure = new Error(`connect localId=${localId}: ${reason}`);
			}
		}
	};
	await Promise.all(Array.from({ length: 250 }, connector));
	if (failure) throw failure;

	// Match the e2e subscribe phase: all clients subscribe after every store
	// scope exists. Keep each connection's subscription sequence ordered so the
	// server cannot coalesce setup responses into fewer frames.
	await Promise.all(
		connections.map(async (conn, localId) => {
			const filter = localId < clientsPerProcess / 2 ? "A" : "B";
			conn.sendBase64(corpus.setup.storeSubscribes[table][filter]);
			await conn.waitFor(3);
			noteSetup("store-subscribe", conn);
			conn.sendBase64(presenceNamespace);
			await conn.waitFor(4);
			noteSetup("presence-namespace", conn);
			conn.sendBase64(corpus.setup.presenceSubscribe);
			await conn.waitFor(5);
			noteSetup("presence-subscribe", conn);
			conn.sendBase64(corpus.setup.presenceSubscribeShared);
			await conn.waitFor(6);
			noteSetup("presence-subscribe-shared", conn);
		}),
	);
} catch (error) {
	process.send?.({
		type: "error",
		message: error instanceof Error ? error.message : String(error),
	});
	throw error;
}

const failedSetup = Object.entries(setupFail).filter(([, count]) => count > 0);
if (failedSetup.length > 0) {
	const message = `setup failures: ${failedSetup
		.map(([stage, count]) => `${stage}=${count}`)
		.join(", ")}`;
	process.send?.({ type: "error", message });
	throw new Error(message);
}

process.send?.({
	type: "ready",
	process: processIndex,
	connections: connections.length,
});

function phaseCreates(): Promise<void> {
	return Promise.all(
		connections.slice(0, 100).map(async (conn, idx) => {
			const target = conn.acks + 1;
			conn.sendBase64(createFrames[idx]);
			await conn.waitForAcks(target);
		}),
	).then(() => {});
}

function phaseUpdates(): Promise<void> {
	return Promise.all(
		connections.slice(100, 200).map(async (conn, idx) => {
			const target = conn.acks + 1;
			conn.sendBase64(updateFrames[idx]);
			await conn.waitForAcks(target);
		}),
	).then(() => {});
}

async function phasePresenceUser(): Promise<void> {
	for (let tick = 0; tick < 3; tick++) {
		for (let i = 0; i < 100; i++) {
			const localId = 200 + i;
			const conn = connections[localId];
			const globalId = processIndex * clientsPerProcess + localId;
			const frames = corpus.presenceUser[String(globalId)];
			if (!frames) throw new Error(`missing presence user ${globalId}`);
			conn.sendBase64(frames[tick]);
		}
		if (tick < 2) await Bun.sleep(25);
	}
}

async function phasePresenceShared(): Promise<void> {
	for (let tick = 0; tick < 3; tick++) {
		for (let i = 0; i < 100; i++) {
			connections[300 + i].sendBase64(sharedFrames[tick]);
		}
		if (tick < 2) await Bun.sleep(25);
	}
}

function totalFrames(): number {
	let total = 0;
	for (const conn of connections) total += conn.frames;
	return total;
}

function totalBytes(): number {
	let total = 0;
	for (const conn of connections) total += conn.bytes;
	return total;
}

function countClosed(): number {
	let closed = 0;
	for (const conn of connections) if (conn.closed) closed++;
	return closed;
}

let probeFramesBefore = 0;
let workloadFrames = -1;
let workloadBytes = -1;

async function fireProbe(): Promise<void> {
	const presence =
		corpus.presenceUser[String(processIndex * clientsPerProcess + 200)]?.[0];
	if (!presence) throw new Error("probe: missing template presence frame");
	const writer = connections[0];
	const target = writer.acks + 1;
	writer.sendBase64(createFrames[0]);
	await writer.waitForAcks(target);
	connections[200].sendBase64(presence);
}

async function phaseConverge(): Promise<void> {
	let last = totalFrames();
	let quietMs = 0;
	while (quietMs < 100) {
		await Bun.sleep(10);
		const current = totalFrames();
		if (current === last) quietMs += 10;
		else {
			last = current;
			quietMs = 0;
		}
	}
}

const phaseFrames: Record<string, number> = {};

async function runPhase(phase: Phase): Promise<void> {
	const before = totalFrames();
	switch (phase) {
		case "store-create":
			await phaseCreates();
			break;
		case "store-update":
			await phaseUpdates();
			break;
		case "presence-user":
			await phasePresenceUser();
			break;
		case "presence-shared":
			await phasePresenceShared();
			break;
		case "converge":
			await phaseConverge();
			break;
	}
	phaseFrames[phase] = totalFrames() - before;
}

process.on("message", (message: unknown) => {
	if (!message || typeof message !== "object") return;
	const record = message as { type?: string; phase?: Phase };
	if (record.type === "phase" && record.phase) {
		runPhase(record.phase)
			.then(() =>
				process.send?.({
					type: "phase-done",
					process: processIndex,
					shard,
					phase: record.phase,
				}),
			)
			.catch((error: unknown) => {
				process.send?.({
					type: "error",
					message: error instanceof Error ? error.message : String(error),
				});
			});
	}
	if (record.type === "probe-arm") {
		workloadFrames = totalFrames();
		workloadBytes = totalBytes();
		probeFramesBefore = workloadFrames;
		process.send?.({ type: "probe-armed", shard, process: processIndex });
	}
	if (record.type === "probe-fire") {
		fireProbe()
			.then(() => process.send?.({ type: "probe-fired" }))
			.catch((error: unknown) => {
				process.send?.({
					type: "error",
					message: error instanceof Error ? error.message : String(error),
				});
			});
	}
	if (record.type === "probe-collect") {
		process.send?.({
			type: "probe-collected",
			shard,
			process: processIndex,
			framesBefore: probeFramesBefore,
			framesAfter: totalFrames(),
		});
	}
	if (record.type === "cleanup") {
		const closed = countClosed();
		for (const conn of connections) conn.close();
		const cpu = process.cpuUsage(cpuStart);
		process.send?.({
			type: "result",
			process: processIndex,
			shard,
			connections: connections.length,
			closed,
			frames: workloadFrames >= 0 ? workloadFrames : totalFrames(),
			bytes: workloadBytes >= 0 ? workloadBytes : totalBytes(),
			phaseFrames,
			setupFail,
			cpuMs: (cpu.user + cpu.system) / 1000,
		});
	}
});
