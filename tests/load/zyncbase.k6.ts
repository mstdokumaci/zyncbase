import { sleep } from "k6";
import http from "k6/http";
import exec from "k6/execution";
import { Counter, Rate, Trend } from "k6/metrics";
import { WebSocket } from "k6/websockets";

import {
	decodeMessages,
	documentId,
	encodeMessage,
	pairValue,
	WireMessageType,
	WireSchema,
	type WireMessage,
} from "./protocol.ts";

declare const __ENV: Record<string, string | undefined>;

const profiles = [
	"connections",
	"store-accepted",
	"store-committed",
	"store-identical-filter",
	"presence-user",
	"presence-shared",
] as const;
type Profile = (typeof profiles)[number];
type Role =
	| "connection"
	| "store-writer"
	| "store-subscriber"
	| "presence-user-writer"
	| "presence-user-subscriber"
	| "presence-shared-writer"
	| "presence-shared-subscriber";

const profile = enumEnv("PROFILE", profiles, "connections");
const smoke = __ENV.SMOKE === "1";
const socketsPerVu = intEnv("SOCKETS_PER_VU", 30);
const clients = intEnv("CLIENTS", smoke ? 5 : 5_000);
const subscribers = intEnv("SUBSCRIBERS", smoke ? 3 : 5_000);
const defaultWriters = profile === "presence-shared" ? 1 : smoke ? 2 : 32;
const writers = intEnv(
	"WRITERS",
	profile === "store-identical-filter" || profile.startsWith("presence-")
		? defaultWriters
		: clients,
);
const fanoutProfile =
	profile === "store-identical-filter" || profile.startsWith("presence-");
const setupSeconds = intEnv(
	"SETUP_SECONDS",
	smoke ? 4 : fanoutProfile ? 45 : 20,
);
const connectRampSeconds = nonNegativeIntEnv(
	"CONNECT_RAMP_SECONDS",
	smoke ? 0 : fanoutProfile ? 15 : 10,
);
const barrierSeconds = intEnv("BARRIER_SECONDS", 1);
const warmupSeconds = intEnv("WARMUP_SECONDS", smoke ? 1 : 10);
const measureSeconds = intEnv("DURATION_SECONDS", smoke ? 3 : 30);
const cooldownSeconds = intEnv("COOLDOWN_SECONDS", smoke ? 3 : 10);
const rate = intEnv("RATE", fanoutProfile ? 100 : 10_000);
const probeRate = intEnv("PROBE_RATE", smoke ? 2 : 1);
const maxBufferedBytes = intEnv("MAX_BUFFERED_BYTES", 1_048_576);
const maxCatchup = intEnv("MAX_CATCHUP", 1_000);
const maxInflight = intEnv("MAX_INFLIGHT", 64);
const maxEventLoopLagMs = intEnv("MAX_EVENT_LOOP_LAG_MS", 250);
const wsUrl = __ENV.WS_URL ?? "ws://127.0.0.1:3000";
const namespace = __ENV.NAMESPACE ?? "load";
const resultPath = __ENV.RESULT_PATH ?? "test-artifacts/load/latest/k6-summary.json";
const finalSequenceBase = 1_000_000_000;

const totalConnections = fanoutProfile ? subscribers + writers : clients;
const vus = Math.ceil(totalConnections / socketsPerVu);
const totalSeconds =
	setupSeconds +
	barrierSeconds +
	warmupSeconds +
	measureSeconds +
	cooldownSeconds;

if (!smoke && totalConnections < 5_000) {
	throw new Error(
		`Benchmark profiles require at least 5000 connections, got ${totalConnections}`,
	);
}
if (profile === "presence-shared" && writers !== 1) {
	throw new Error("presence-shared requires exactly one writer");
}
if (connectRampSeconds >= setupSeconds) {
	throw new Error("CONNECT_RAMP_SECONDS must be shorter than SETUP_SECONDS");
}

const ready = new Rate("load_ready");
const ticketErrors = new Counter("load_ticket_errors");
const protocolErrors = new Counter("load_protocol_errors");
const serverErrors = new Counter("load_server_errors");
const unexpectedCloses = new Counter("load_unexpected_closes");
const backpressure = new Counter("load_generator_backpressure");
const lagEvents = new Counter("load_generator_lag_events");
const scheduleLag = new Trend("load_generator_schedule_lag_ms");
const eventLoopLagEvents = new Counter("load_generator_event_loop_lag_events");
const eventLoopLag = new Trend("load_generator_event_loop_lag_ms");
const loadMessages = new Counter("load_messages");
const acceptedWrites = new Counter("load_accepted_writes");
const committedWrites = new Counter("load_committed_writes");
const writeErrors = new Counter("load_write_errors");
const commitLatency = new Trend("load_commit_latency_ms", true);
const storeDeltaOps = new Counter("load_store_delta_ops");
const userPresenceUpdates = new Counter("load_presence_user_updates");
const sharedPresencePatches = new Counter("load_presence_shared_patches");
const fanoutDeliveries = new Counter("load_fanout_deliveries");
const probeLatency = new Trend("load_probe_latency_ms", true);
const finalConvergence = new Rate("load_final_convergence");

const thresholds: Record<string, string[]> = {
	load_ready: ["rate==1"],
	load_ticket_errors: ["count==0"],
	load_protocol_errors: ["count==0"],
	load_server_errors: ["count==0"],
	load_unexpected_closes: ["count==0"],
	load_generator_backpressure: ["count==0"],
	load_generator_lag_events: ["count==0"],
	load_generator_event_loop_lag_events: ["count==0"],
	load_write_errors: ["count==0"],
};
if (profile !== "connections") thresholds.load_final_convergence = ["rate==1"];
if (profile !== "connections") {
	thresholds.load_messages = [
		`count>=${Math.floor(rate * measureSeconds * 0.98)}`,
	];
}

export const options = {
	discardResponseBodies: false,
	batch: socketsPerVu,
	batchPerHost: socketsPerVu,
	scenarios: {
		load: {
			executor: "per-vu-iterations",
			vus,
			iterations: 1,
			maxDuration: `${totalSeconds + 15}s`,
			exec: "run",
		},
	},
	thresholds,
};

interface Assignment {
	role: Role;
	id: number;
}

interface Timeline {
	setupEnd: number;
	loadStart: number;
	measureStart: number;
	measureEnd: number;
	finalCheck: number;
}

interface CommitInfo {
	startedAt: number;
	measured: boolean;
}

interface FanoutCounts {
	store: number;
	user: number;
	shared: number;
}

class RawClient {
	readonly role: Role;
	readonly logicalId: number;
	readonly socket: WebSocket;
	readonly phase: () => string;

	private schema?: WireSchema;
	private opened = false;
	private connected = false;
	private namespaceReady = false;
	private subscriptionStarted = false;
	private expectedClose = false;
	private failed = false;
	private nextRequestId = 1;
	private pending = new Map<number, (message: WireMessage) => void>();
	private frames: Uint8Array[] = [];
	private frameIndex = 0;
	private sequence = 2;
	private probeSequence = 10_000_000;
	private finalWriteId?: string;
	private finalAccepted = false;
	private finalCommitted = false;
	private finalSent = false;
	private inflight = new Map<string, CommitInfo>();
	private lastSequences?: Int32Array;
	private tableIndex = -1;
	private matchField = -1;
	private writerField = -1;
	private sequenceField = -1;
	private probeField = -1;
	private fanoutCounts: FanoutCounts = { store: 0, user: 0, shared: 0 };

	constructor(assignment: Assignment, ticket: string, phase: () => string) {
		this.role = assignment.role;
		this.logicalId = assignment.id;
		this.phase = phase;
		if (this.isSubscriber()) {
			this.lastSequences = new Int32Array(writers);
			this.lastSequences.fill(-1);
		}

		const separator = wsUrl.includes("?") ? "&" : "?";
		this.socket = new WebSocket(
			`${wsUrl}${separator}ticket=${encodeURIComponent(ticket)}`,
			undefined,
			{ tags: { profile, role: this.role } },
		);
		this.socket.binaryType = "arraybuffer";
		this.socket.addEventListener("open", () => this.onOpen());
		this.socket.addEventListener("message", (event) =>
			this.onMessage(event.data as ArrayBuffer),
		);
		this.socket.addEventListener("error", () => this.fail("websocket error"));
		this.socket.addEventListener("close", () => {
			if (!this.expectedClose) unexpectedCloses.add(1, this.tags());
		});
	}

	isReady(): boolean {
		return !this.failed && this.frames.length > 0;
	}

	failure(): boolean {
		return this.failed;
	}

	sendLoad(measured: boolean): boolean {
		if (!this.isWriter() || !this.isReady()) return false;
		if (profile === "store-committed") {
			if (this.inflight.size >= maxInflight) {
				backpressure.add(1, this.tags("measure"));
				return false;
			}
			const sequence = this.sequence++;
			return this.sendCommittedStore(sequence, 0, measured, false);
		}
		const sent = this.send(this.frames[this.frameIndex++ & 1]);
		if (sent && measured) loadMessages.add(1, this.tags("measure"));
		return sent;
	}

	sendProbe(): void {
		if (!this.isReady()) return;
		const sequence = this.probeSequence++;
		const sentAt = Date.now();
		if (this.role === "store-writer") {
			this.send(this.storeFrame(sequence, sentAt, "accepted"));
		} else if (this.role === "presence-user-writer") {
			this.send(this.presenceFrame(sequence, sentAt, false));
		} else if (this.role === "presence-shared-writer") {
			this.send(this.presenceFrame(sequence, sentAt, true));
		}
	}

	sendFinal(): boolean {
		if (this.finalSent) return true;
		if (!this.isWriter() || !this.isReady()) return false;
		const sequence = finalSequenceBase + this.logicalId;
		let sent: boolean;
		if (this.role === "store-writer") {
			if (profile === "store-accepted") {
				const id = this.nextRequestId++;
				this.pending.set(id, () => {
					this.finalAccepted = true;
				});
				sent = this.send(
					this.storeFrame(sequence, 0, "accepted", undefined, id),
					false,
				);
				if (!sent) {
					this.pending.delete(id);
				}
			} else {
				sent = this.sendCommittedStore(sequence, 0, false, true, false);
			}
		} else if (this.role === "presence-user-writer") {
			sent = this.send(this.presenceFrame(sequence, 0, false), false);
		} else if (this.role === "presence-shared-writer") {
			sent = this.send(this.presenceFrame(sequence, 0, true), false);
		} else {
			return false;
		}
		this.finalSent = sent;
		return sent;
	}

	validateFinal(): void {
		if (this.role === "store-writer") {
			finalConvergence.add(
				profile === "store-accepted"
					? this.finalAccepted
					: this.finalCommitted &&
						(profile !== "store-committed" || this.inflight.size === 0),
				this.tags("cooldown"),
			);
			return;
		}
		if (!this.isSubscriber()) return;
		let converged = true;
		for (let writer = 0; writer < writers; writer++) {
			if (this.lastSequences?.[writer] !== finalSequenceBase + writer) {
				converged = false;
				break;
			}
		}
		finalConvergence.add(converged, this.tags("cooldown"));
	}

	close(): void {
		this.expectedClose = true;
		this.socket.close();
	}

	drainFanoutCounts(): FanoutCounts {
		const counts = this.fanoutCounts;
		this.fanoutCounts = { store: 0, user: 0, shared: 0 };
		return counts;
	}

	private onOpen(): void {
		this.opened = true;
		if (this.role === "connection") {
			this.maybeInitialize();
			return;
		}
		const type = this.role.startsWith("store-")
			? WireMessageType.StoreSetNamespace
			: WireMessageType.PresenceSetNamespace;
		this.request({ type, namespace }, () => {
			this.namespaceReady = true;
			this.maybeInitialize();
		});
	}

	private onMessage(data: ArrayBuffer): void {
		let messages: WireMessage[];
		try {
			messages = decodeMessages(data);
		} catch (error) {
			this.fail(`MessagePack decode: ${String(error)}`);
			return;
		}
		for (const message of messages) this.handleMessage(message);
	}

	private handleMessage(message: WireMessage): void {
		switch (message.type) {
			case WireMessageType.Connected:
				this.connected = true;
				this.maybeInitialize();
				return;
			case WireMessageType.SchemaSync:
				try {
					this.schema = new WireSchema(message as never);
					this.cacheFieldIndexes();
					this.maybeInitialize();
				} catch (error) {
					this.fail(String(error));
				}
				return;
			case WireMessageType.ok:
				this.handleOk(message);
				return;
			case WireMessageType.error:
				serverErrors.add(1, this.tags());
				this.pending.delete(numberValue(message.id));
				this.fail(`server error ${String(message.code)}: ${String(message.message)}`);
				return;
			case WireMessageType.WriteCommitted:
				this.handleCommitted(String(message.writeId));
				return;
			case WireMessageType.WriteError:
				writeErrors.add(1, this.tags());
				this.inflight.delete(String(message.writeId));
				return;
			case WireMessageType.StoreDelta:
				this.handleStoreDelta(message.ops);
				return;
			case WireMessageType.PresenceBroadcast:
				this.handlePresenceUsers(message.users);
				return;
			case WireMessageType.SharedStateBroadcast:
				this.handleSharedPresence(message.data);
				return;
		}
	}

	private handleOk(message: WireMessage): void {
		const id = numberValue(message.id);
		if (id === 0) {
			if (this.phase() === "measure" && this.role === "store-writer") {
				acceptedWrites.add(1, this.tags("measure"));
			}
			return;
		}
		const callback = this.pending.get(id);
		if (!callback) {
			this.fail(`unexpected response id ${id}`);
			return;
		}
		this.pending.delete(id);
		callback(message);
	}

	private handleCommitted(writeId: string): void {
		const info = this.inflight.get(writeId);
		if (!info) {
			this.fail(`unexpected WriteCommitted ${writeId}`);
			return;
		}
		this.inflight.delete(writeId);
		if (info.measured) {
			committedWrites.add(1, this.tags("measure"));
			commitLatency.add(Date.now() - info.startedAt, this.tags("measure"));
		}
		if (writeId === this.finalWriteId) this.finalCommitted = true;
	}

	private handleStoreDelta(rawOps: unknown): void {
		if (!Array.isArray(rawOps)) return;
		let count = 0;
		for (const rawOp of rawOps) {
			if (!rawOp || typeof rawOp !== "object") continue;
			const value = (rawOp as Record<string, unknown>).value;
			this.observe(
				pairValue(value, this.writerField),
				pairValue(value, this.sequenceField),
				pairValue(value, this.probeField),
			);
			count++;
		}
		if (count > 0 && this.phase() === "measure") {
			this.fanoutCounts.store += count;
		}
	}

	private handlePresenceUsers(rawUsers: unknown): void {
		if (!Array.isArray(rawUsers)) return;
		let count = 0;
		for (const rawUser of rawUsers) {
			if (!rawUser || typeof rawUser !== "object") continue;
			const data = (rawUser as Record<string, unknown>).data;
			this.observe(
				pairValue(data, this.writerField),
				pairValue(data, this.sequenceField),
				pairValue(data, this.probeField),
			);
			count++;
		}
		if (count > 0 && this.phase() === "measure") {
			this.fanoutCounts.user += count;
		}
	}

	private handleSharedPresence(rawPatches: unknown): void {
		if (!Array.isArray(rawPatches)) return;
		let count = 0;
		for (const patch of rawPatches) {
			this.observe(
				pairValue(patch, this.writerField),
				pairValue(patch, this.sequenceField),
				pairValue(patch, this.probeField),
			);
			count++;
		}
		if (count > 0 && this.phase() === "measure") {
			this.fanoutCounts.shared += count;
		}
	}

	private observe(rawWriter: unknown, rawSequence: unknown, rawProbe: unknown): void {
		if (typeof rawWriter !== "number" || typeof rawSequence !== "number") return;
		if (rawWriter < 0 || rawWriter >= writers) return;
		if (this.lastSequences) this.lastSequences[rawWriter] = rawSequence;
		if (typeof rawProbe === "number" && rawProbe > 0 && this.phase() === "measure") {
			probeLatency.add(Date.now() - rawProbe, this.tags("measure"));
		}
	}

	private maybeInitialize(): void {
		if (this.frames.length > 0 || !this.opened || !this.schema) return;
		if (this.role === "connection") {
			if (!this.connected) return;
			this.frames = [new Uint8Array(), new Uint8Array()];
			ready.add(true, this.tags("setup"));
			return;
		}
		if (!this.namespaceReady) return;
		if (this.isSubscriber()) {
			if (this.subscriptionStarted) return;
			this.subscriptionStarted = true;
			const type =
				this.role === "store-subscriber"
					? WireMessageType.StoreSubscribe
					: this.role === "presence-user-subscriber"
						? WireMessageType.PresenceSubscribe
						: WireMessageType.PresenceSubscribeShared;
			const message: WireMessage = { type };
			if (type === WireMessageType.StoreSubscribe) {
				message.table_index = this.tableIndex;
				message.conditions = [[this.matchField, 0, true]];
			}
			this.request(message, () => this.markReady());
			return;
		}
		this.frames = this.buildFrames();
		this.markReady();
	}

	private markReady(): void {
		if (this.frames.length === 0) {
			this.frames = [new Uint8Array(), new Uint8Array()];
		}
		ready.add(true, this.tags("setup"));
	}

	private buildFrames(): Uint8Array[] {
		if (this.role === "store-writer") {
			return [this.storeFrame(0, 0, "accepted"), this.storeFrame(1, 0, "accepted")];
		}
		if (this.role === "presence-user-writer") {
			return [this.presenceFrame(0, 0, false), this.presenceFrame(1, 0, false)];
		}
		if (this.role === "presence-shared-writer") {
			return [this.presenceFrame(0, 0, true), this.presenceFrame(1, 0, true)];
		}
		return [new Uint8Array(), new Uint8Array()];
	}

	private storeFrame(
		sequence: number,
		probeSentAt: number,
		confirm: "accepted" | "committed",
		writeId?: string,
		id = 0,
	): Uint8Array {
		return encodeMessage({
			type: WireMessageType.StoreSet,
			id,
			path: [this.tableIndex, documentId(this.logicalId)],
			value: [
				[this.matchField, true],
				[this.writerField, this.logicalId],
				[this.sequenceField, sequence],
				[this.probeField, probeSentAt],
			],
			confirm,
			...(writeId ? { writeId } : {}),
		});
	}

	private presenceFrame(
		sequence: number,
		probeSentAt: number,
		shared: boolean,
	): Uint8Array {
		return encodeMessage({
			type: shared
				? WireMessageType.PresenceSetShared
				: WireMessageType.PresenceSet,
			id: 0,
			data: [
				[this.writerField, this.logicalId],
				[this.sequenceField, sequence],
				[this.probeField, probeSentAt],
			],
		});
	}

	private sendCommittedStore(
		sequence: number,
		probeSentAt: number,
		measured: boolean,
		final: boolean,
		reportBackpressure = true,
	): boolean {
		const writeId = makeWriteId(this.logicalId, sequence);
		const sent = this.send(
			this.storeFrame(sequence, probeSentAt, "committed", writeId),
			reportBackpressure,
		);
		if (!sent) return false;
		this.inflight.set(writeId, { startedAt: Date.now(), measured });
		if (measured) loadMessages.add(1, this.tags("measure"));
		if (final) this.finalWriteId = writeId;
		return true;
	}

	private request(
		message: Omit<WireMessage, "id">,
		callback: (message: WireMessage) => void,
	): void {
		const id = this.nextRequestId++;
		this.pending.set(id, callback);
		if (!this.send(encodeMessage({ ...message, id }))) {
			this.pending.delete(id);
			this.fail("failed to send setup request");
		}
	}

	private send(bytes: Uint8Array, reportBackpressure = true): boolean {
		if (this.socket.readyState !== 1) return false;
		if (this.socket.bufferedAmount > maxBufferedBytes) {
			if (reportBackpressure) backpressure.add(1, this.tags());
			return false;
		}
		this.socket.send(bytes);
		return true;
	}

	private isWriter(): boolean {
		return this.role.endsWith("-writer");
	}

	private cacheFieldIndexes(): void {
		const schema = this.schema as WireSchema;
		if (this.role.startsWith("store-")) {
			this.tableIndex = schema.table("bench");
			this.matchField = schema.field(this.tableIndex, "match");
			this.writerField = schema.field(this.tableIndex, "writer");
			this.sequenceField = schema.field(this.tableIndex, "sequence");
			this.probeField = schema.field(this.tableIndex, "probeSentAt");
			return;
		}
		if (this.role.startsWith("presence-shared-")) {
			this.writerField = schema.presenceSharedField("writer");
			this.sequenceField = schema.presenceSharedField("sequence");
			this.probeField = schema.presenceSharedField("probeSentAt");
			return;
		}
		if (this.role.startsWith("presence-user-")) {
			this.writerField = schema.presenceUserField("writer");
			this.sequenceField = schema.presenceUserField("sequence");
			this.probeField = schema.presenceUserField("probeSentAt");
		}
	}

	private isSubscriber(): boolean {
		return this.role.endsWith("-subscriber");
	}

	private fail(message: string): void {
		if (this.failed) return;
		this.failed = true;
		protocolErrors.add(1, this.tags());
		console.error(`${this.role} ${this.logicalId}: ${message}`);
	}

	private tags(phase = this.phase()): Record<string, string> {
		return { profile, phase, role: this.role };
	}
}

export function run(): void {
	const vuIndex = exec.vu.idInTest - 1;
	const assignments = assignmentsForVu(vuIndex);
	if (assignments.length === 0) return;
	const startedAt = Number(exec.scenario.startTime);
	const timeline: Timeline = {
		setupEnd: startedAt + setupSeconds * 1_000,
		loadStart: startedAt + (setupSeconds + barrierSeconds) * 1_000,
		measureStart:
			startedAt + (setupSeconds + barrierSeconds + warmupSeconds) * 1_000,
		measureEnd:
			startedAt +
			(setupSeconds + barrierSeconds + warmupSeconds + measureSeconds) * 1_000,
		finalCheck: startedAt + totalSeconds * 1_000 - 500,
	};
	sleep((connectRampSeconds * vuIndex) / vus);
	const phase = () => phaseAt(timeline, Date.now());
	const tickets = acquireTickets(assignments);
	const clientsForVu = assignments.map(
		(assignment, index) => new RawClient(assignment, tickets[index], phase),
	);
	const writersForVu = clientsForVu.filter((client) => client.role.endsWith("-writer"));
	const flushFanoutMetrics = () => {
		let store = 0;
		let user = 0;
		let shared = 0;
		for (const client of clientsForVu) {
			const counts = client.drainFanoutCounts();
			store += counts.store;
			user += counts.user;
			shared += counts.shared;
		}
		const tags = { profile, phase: "measure" };
		if (store > 0) storeDeltaOps.add(store, tags);
		if (user > 0) userPresenceUpdates.add(user, tags);
		if (shared > 0) sharedPresencePatches.add(shared, tags);
		if (store + user + shared > 0) {
			fanoutDeliveries.add(store + user + shared, tags);
		}
	};
	const metricFlush = setInterval(flushFanoutMetrics, 1_000);
	at(startedAt + totalSeconds * 1_000, () => {
		clearInterval(metricFlush);
		flushFanoutMetrics();
	});
	let expectedWatchdogAt = Date.now() + 100;
	const watchdog = setInterval(() => {
		const now = Date.now();
		const lag = now - expectedWatchdogAt;
		if (lag > maxEventLoopLagMs && phase() === "measure") {
			eventLoopLagEvents.add(1, { profile, phase: "measure" });
			eventLoopLag.add(lag, { profile, phase: "measure" });
		}
		expectedWatchdogAt = now + 100;
	}, 100);
	at(startedAt + totalSeconds * 1_000, () => clearInterval(watchdog));

	at(timeline.setupEnd, () => {
		const invalid = clientsForVu.filter(
			(client) => !client.isReady() || client.failure(),
		);
		for (const client of invalid) ready.add(false, { profile, phase: "setup" });
		if (invalid.length > 0) {
			exec.test.abort(`${invalid.length} clients failed setup in VU ${exec.vu.idInTest}`);
		}
	});

	if (writersForVu.length > 0) {
		const localRate = (rate * writersForVu.length) / writers;
		let sent = 0;
		let cursor = 0;
		const pump = setInterval(() => {
			const now = Date.now();
			if (now < timeline.loadStart || now >= timeline.measureEnd) return;
			const expected = Math.floor(
				((now - timeline.loadStart) * localRate) / 1_000,
			);
			let due = expected - sent;
			if (due > maxCatchup) {
				lagEvents.add(1, { profile, phase: phase() });
				scheduleLag.add((due * 1_000) / localRate, { profile, phase: phase() });
				due = maxCatchup;
			}
			for (let index = 0; index < due; index++) {
				const client = writersForVu[cursor++ % writersForVu.length];
				if (client.sendLoad(now >= timeline.measureStart)) sent++;
			}
		}, 10);
		at(timeline.measureEnd, () => clearInterval(pump));

		const probeWriter = writersForVu.find((client) => client.logicalId === 0);
		if (probeWriter && fanoutProfile && probeRate > 0) {
			const probes = setInterval(() => {
				const now = Date.now();
				if (now >= timeline.measureStart && now < timeline.measureEnd) {
					probeWriter.sendProbe();
				}
			}, Math.max(1, Math.floor(1_000 / probeRate)));
			at(timeline.measureEnd, () => clearInterval(probes));
		}

		let finalRetry: ReturnType<typeof setInterval> | undefined;
		at(timeline.measureEnd, () => {
			let pending = writersForVu;
			const sendFinals = () => {
				pending = pending.filter((client) => !client.sendFinal());
				if (pending.length === 0 && finalRetry !== undefined) {
					clearInterval(finalRetry);
				}
			};
			sendFinals();
			if (pending.length > 0) finalRetry = setInterval(sendFinals, 100);
		});
		at(timeline.finalCheck, () => {
			if (finalRetry !== undefined) clearInterval(finalRetry);
		});
	}

	at(timeline.finalCheck, () =>
		clientsForVu.forEach((client) => client.validateFinal()),
	);
	at(startedAt + totalSeconds * 1_000, () =>
		clientsForVu.forEach((client) => client.close()),
	);
}

function assignmentsForVu(vuIndex: number): Assignment[] {
	const start = vuIndex * socketsPerVu;
	const end = Math.min(start + socketsPerVu, totalConnections);
	const assignments: Assignment[] = [];
	for (let connection = start; connection < end; connection++) {
		assignments.push(assignment(connection));
	}
	return assignments;
}

function assignment(connection: number): Assignment {
	if (profile === "connections") return { role: "connection", id: connection };
	if (profile === "store-accepted" || profile === "store-committed") {
		return { role: "store-writer", id: connection };
	}
	if (connection < subscribers) {
		if (profile === "store-identical-filter") {
			return { role: "store-subscriber", id: connection };
		}
		if (profile === "presence-user") {
			return { role: "presence-user-subscriber", id: connection };
		}
		return { role: "presence-shared-subscriber", id: connection };
	}
	const id = connection - subscribers;
	if (profile === "store-identical-filter") return { role: "store-writer", id };
	if (profile === "presence-user") return { role: "presence-user-writer", id };
	return { role: "presence-shared-writer", id };
}

function acquireTickets(assignments: Assignment[]): string[] {
	const endpoint = `${wsUrl.replace(/^ws/, "http").replace(/\/$/, "")}/auth/ticket`;
	const responses = http.batch(
		assignments.map((item) => ({
			method: "POST",
			url: endpoint,
			body: JSON.stringify({ anonymousSubject: anonymousSubject(item) }),
			params: {
				headers: { "Content-Type": "application/json" },
				tags: { profile, role: item.role, endpoint: "ticket" },
			},
		})),
	);
	return responses.map((response, index) => {
		if (response.status !== 200) {
			ticketErrors.add(1, { profile, role: assignments[index].role });
			exec.test.abort(`ticket exchange failed with HTTP ${response.status}`);
		}
		const body = JSON.parse(String(response.body)) as { ticket?: string };
		if (!body.ticket) {
			ticketErrors.add(1, { profile, role: assignments[index].role });
			exec.test.abort("ticket exchange response did not contain a ticket");
		}
		return body.ticket;
	});
}

function anonymousSubject(item: Assignment): string {
	const roleCode = [
		"connection",
		"store-writer",
		"store-subscriber",
		"presence-user-writer",
		"presence-user-subscriber",
		"presence-shared-writer",
		"presence-shared-subscriber",
	].indexOf(item.role);
	const unique = `${roleCode.toString(16).padStart(8, "0")}${item.id
		.toString(16)
		.padStart(16, "0")}`;
	return `anon:${(unique + "a5".repeat(32)).slice(0, 64)}`;
}

function makeWriteId(writer: number, sequence: number): string {
	return `${writer.toString(16).padStart(8, "0")}${sequence
		.toString(16)
		.padStart(16, "0")}00000000`;
}

function phaseAt(timeline: Timeline, now: number): string {
	if (now < timeline.loadStart) return "setup";
	if (now < timeline.measureStart) return "warmup";
	if (now < timeline.measureEnd) return "measure";
	return "cooldown";
}

function numberValue(value: unknown): number {
	return typeof value === "number" ? value : -1;
}

function intEnv(name: string, fallback: number): number {
	const value = __ENV[name] === undefined ? fallback : Number(__ENV[name]);
	if (!Number.isInteger(value) || value <= 0) {
		throw new Error(`${name} must be a positive integer`);
	}
	return value;
}

function nonNegativeIntEnv(name: string, fallback: number): number {
	const value = __ENV[name] === undefined ? fallback : Number(__ENV[name]);
	if (!Number.isInteger(value) || value < 0) {
		throw new Error(`${name} must be a non-negative integer`);
	}
	return value;
}

function at(timestamp: number, callback: () => void): void {
	setTimeout(callback, Math.max(0, timestamp - Date.now()));
}

function enumEnv<const T extends readonly string[]>(
	name: string,
	values: T,
	fallback: T[number],
): T[number] {
	const value = __ENV[name] ?? fallback;
	if (!values.includes(value as T[number])) {
		throw new Error(`${name} must be one of ${values.join(", ")}`);
	}
	return value as T[number];
}

export function handleSummary(data: unknown): Record<string, string> {
	const benchmarkEligible = !smoke && summaryThresholdsPassed(data);
	return {
		[resultPath]: JSON.stringify(
			{
				benchmarkEligible,
				profile,
				config: {
					totalConnections,
					clients,
					subscribers: fanoutProfile ? subscribers : 0,
					writers: profile === "connections" ? 0 : writers,
					vus,
					rate,
					setupSeconds,
					connectRampSeconds,
					warmupSeconds,
					measureSeconds,
					cooldownSeconds,
					maxEventLoopLagMs,
				},
				k6: data,
			},
			null,
			2,
		),
		stdout: `${smoke ? "SMOKE" : "BENCHMARK"} ${profile}: ${totalConnections} connections, target ${rate} msg/s\n`,
	};
}

function summaryThresholdsPassed(data: unknown): boolean {
	const metrics = (data as { metrics?: Record<string, unknown> }).metrics ?? {};
	for (const metric of Object.values(metrics)) {
		const thresholdResults = (
			metric as { thresholds?: Record<string, { ok?: boolean }> }
		).thresholds;
		if (
			thresholdResults &&
			Object.values(thresholdResults).some((result) => result.ok === false)
		) {
			return false;
		}
	}
	return true;
}
