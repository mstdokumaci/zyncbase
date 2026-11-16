// biome-ignore-all lint/complexity/noExcessiveCognitiveComplexity: action handlers are linear protocol sequences with explicit guards.
import {
	type ActionContext,
	ActionError,
	type BatchOperation,
	createClient,
	ErrorCodes,
	ZyncBaseError,
} from "@zyncbase/client";
import type {
	ZyncBaseActions,
	ZyncBasePresence,
	ZyncBaseSchema,
} from "./schema-types";
import {
	type BallotRow,
	type BudgetRow,
	type CardRow,
	clampCard,
	clampName,
	clampTitle,
	colorForIndex,
	DEFAULT_MAX_PER_CARD,
	DEFAULT_VOTE_BUDGET,
	isReadOnlyPhase,
	isTemplate,
	lanesFor,
	MAX_CARDS,
	MAX_MEMBERS,
	MAX_VOTE_DURATION_MS,
	type MemberRow,
	MIN_VOTE_DURATION_MS,
	type ResultRow,
	type RoomRow,
	roomNamespace,
} from "./shared";

type WorkerClient = ReturnType<
	typeof createClient<ZyncBaseSchema, ZyncBaseActions, ZyncBasePresence>
>;

export interface WorkerHandle {
	client: WorkerClient;
	stop: () => Promise<void>;
}

const ROOM_COLLECTION = "rooms" as const;
const MEMBER_COLLECTION = "members" as const;
const BUDGET_COLLECTION = "budgets" as const;
const CARD_COLLECTION = "cards" as const;
const BALLOT_COLLECTION = "ballots" as const;
const RESULT_COLLECTION = "results" as const;
const DECISION_COLLECTION = "decisions" as const;

const DEMO_NAMES = ["Ana", "Ben", "Cy", "Dee"];
const DEMO_TEXTS = [
	"Ship the small thing before the big thing",
	"Status updates are too long",
	"Pair on the ambiguous work earlier",
	"Protect focus time on release days",
	"Write the decision down",
	"Ask for feedback before polishing",
	"Keep one owner per task",
	"Celebrate the unglamorous fixes",
];

function sleep(ms: number) {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

function isPrecondition(error: unknown): boolean {
	return (
		error instanceof ZyncBaseError &&
		error.code === ErrorCodes.PRECONDITION_FAILED
	);
}

function isUnique(error: unknown): boolean {
	return (
		error instanceof ZyncBaseError &&
		error.code === ErrorCodes.UNIQUE_CONSTRAINT_VIOLATED
	);
}

function phaseError(room: RoomRow): ActionError {
	return new ActionError(
		"WRONG_PHASE",
		`This action is not available during the ${room.phase} phase`,
	);
}

function requirePhase(room: RoomRow, ...phases: RoomRow["phase"][]): void {
	if (!phases.includes(room.phase)) throw phaseError(room);
}

function actorId(ctx: ActionContext): string {
	const external = ctx.claims.external;
	if (typeof external !== "string" || external.length === 0) {
		throw new ActionError("SESSION_INVALID", "Your session has no identity");
	}
	return external;
}

function requireHost(room: RoomRow, ctx: ActionContext): void {
	if (room.host_user_id !== actorId(ctx)) {
		throw new ActionError("NOT_HOST", "Only the facilitator can do that");
	}
}

function cleanTitle(value: string): string {
	const title = clampTitle(value);
	if (title.length === 0) {
		throw new ActionError("INVALID_TITLE", "Give the room a title");
	}
	return title;
}

function cleanName(value: string): string {
	const name = clampName(value);
	if (name.length === 0) {
		throw new ActionError("INVALID_NAME", "Enter a name");
	}
	return name;
}

function cleanCard(value: string): string {
	const text = clampCard(value);
	if (text.length === 0) {
		throw new ActionError("INVALID_CARD", "Enter an idea");
	}
	return text;
}

function clampBudget(value: number | undefined): number {
	if (!Number.isSafeInteger(value)) return DEFAULT_VOTE_BUDGET;
	return Math.min(20, Math.max(1, value as number));
}

function clampPerCard(value: number | undefined, budget: number): number {
	if (!Number.isSafeInteger(value))
		return Math.min(DEFAULT_MAX_PER_CARD, budget);
	return Math.min(budget, Math.max(1, value as number));
}

function clampDuration(value: number): number {
	if (!Number.isSafeInteger(value)) return MIN_VOTE_DURATION_MS;
	return Math.min(MAX_VOTE_DURATION_MS, Math.max(MIN_VOTE_DURATION_MS, value));
}

export async function startWorker(options: {
	code: string;
	url: string;
	tokenProvider: () => Promise<string>;
}): Promise<WorkerHandle> {
	const code = options.code;
	const client = createClient<
		ZyncBaseSchema,
		ZyncBaseActions,
		ZyncBasePresence
	>({
		url: options.url,
		auth: { tokenProvider: options.tokenProvider },
		storeNamespace: roomNamespace(options.code),
	});

	let connected = false;
	for (let attempt = 0; attempt < 100 && !connected; attempt++) {
		try {
			await client.connect();
			connected = true;
		} catch {
			await sleep(100);
		}
	}
	if (!connected) {
		client.disconnect();
		throw new Error("Quorum worker could not connect to ZyncBase");
	}

	async function roomByCode(code: string): Promise<RoomRow | null> {
		const rows = await client.store.query(ROOM_COLLECTION, {
			where: { room_code: code },
			limit: 1,
		});
		return rows[0] ?? null;
	}

	async function memberByUser(
		code: string,
		userId: string,
	): Promise<MemberRow | null> {
		const rows = await client.store.query(MEMBER_COLLECTION, {
			where: { room_code: code, user_id: userId },
			limit: 1,
		});
		return rows[0] ?? null;
	}

	async function budgetFor(
		code: string,
		userId: string,
	): Promise<BudgetRow | null> {
		const rows = await client.store.query(BUDGET_COLLECTION, {
			where: { room_code: code, user_id: userId },
			limit: 1,
		});
		return rows[0] ?? null;
	}

	async function cardFor(
		code: string,
		cardId: string,
	): Promise<CardRow | null> {
		const row = await client.store.get([CARD_COLLECTION, cardId]);
		return row && row.room_code === code ? row : null;
	}

	async function ballotFor(
		code: string,
		round: number,
		userId: string,
		cardId: string,
	): Promise<BallotRow | null> {
		const rows = await client.store.query(BALLOT_COLLECTION, {
			where: {
				room_code: code,
				round,
				user_id: userId,
				card_id: cardId,
			},
			limit: 1,
		});
		return rows[0] ?? null;
	}

	async function allCards(code: string, round: number): Promise<CardRow[]> {
		const rows: CardRow[] = [];
		let after: string | undefined;
		do {
			const page = await client.store.query(CARD_COLLECTION, {
				where: { room_code: code, round },
				orderBy: [{ created_at: "asc" }],
				limit: 200,
				...(after ? { after } : {}),
			});
			rows.push(...page);
			after = page.nextCursor ?? undefined;
		} while (after);
		return rows;
	}

	async function allMembers(code: string): Promise<MemberRow[]> {
		const rows: MemberRow[] = [];
		let after: string | undefined;
		do {
			const page = await client.store.query(MEMBER_COLLECTION, {
				where: { room_code: code },
				orderBy: [{ created_at: "asc" }],
				limit: 200,
				...(after ? { after } : {}),
			});
			rows.push(...page);
			after = page.nextCursor ?? undefined;
		} while (after);
		return rows;
	}

	async function ensureBallots(
		code: string,
		round: number,
		userIds: string[],
		cardIds: string[],
	): Promise<void> {
		if (userIds.length === 0 || cardIds.length === 0) return;
		const existing = await allBallots(code, round);
		const seen = new Set(
			existing.map((ballot) => `${ballot.user_id}\u0000${ballot.card_id}`),
		);
		const operations: BatchOperation[] = [];
		for (const userId of userIds) {
			for (const cardId of cardIds) {
				if (seen.has(`${userId}\u0000${cardId}`)) continue;
				operations.push({
					op: "set",
					path: [BALLOT_COLLECTION, client.utils.id()],
					value: {
						room_code: code,
						round,
						user_id: userId,
						card_id: cardId,
						count: 0,
					},
				});
			}
		}
		for (let index = 0; index < operations.length; index += 400) {
			try {
				await client.store.batch(operations.slice(index, index + 400), {
					confirm: "committed",
				});
			} catch (error) {
				// A concurrent start/join may have created the same rows.
				if (!isUnique(error)) throw error;
			}
		}
	}

	async function allBallots(code: string, round: number): Promise<BallotRow[]> {
		const rows: BallotRow[] = [];
		let after: string | undefined;
		do {
			const page = await client.store.query(BALLOT_COLLECTION, {
				where: { room_code: code, round },
				limit: 200,
				...(after ? { after } : {}),
			});
			rows.push(...page);
			after = page.nextCursor ?? undefined;
		} while (after);
		return rows;
	}

	async function allResults(code: string, round: number): Promise<ResultRow[]> {
		const rows: ResultRow[] = [];
		let after: string | undefined;
		do {
			const page = await client.store.query(RESULT_COLLECTION, {
				where: { room_code: code, round },
				orderBy: [{ rank: "asc" }],
				limit: 200,
				...(after ? { after } : {}),
			});
			rows.push(...page);
			after = page.nextCursor ?? undefined;
		} while (after);
		return rows;
	}

	function demoOperations(
		code: string,
		round: number,
		budget: number,
		maxPerCard: number,
		laneValues: readonly string[],
	): {
		operations: BatchOperation[];
		members: number;
		cards: number;
		votes: number;
	} {
		const operations: BatchOperation[] = [];
		const members = DEMO_NAMES.length;
		const cards = DEMO_TEXTS.length;
		const ballots: Array<{ userId: string; cardId: string; count: number }> =
			[];
		const cardIds: string[] = [];

		for (let index = 0; index < cards; index++) {
			const cardId = client.utils.id();
			cardIds.push(cardId);
			const lane = laneValues[index % laneValues.length] ?? laneValues[0];
			operations.push({
				op: "set",
				path: [CARD_COLLECTION, cardId],
				value: {
					room_code: code,
					round,
					lane,
					text: DEMO_TEXTS[index],
				},
			});
		}

		for (let memberIndex = 0; memberIndex < members; memberIndex++) {
			const memberId = client.utils.id();
			const userId = `demo:${code}:${memberIndex}`;
			operations.push({
				op: "set",
				path: [MEMBER_COLLECTION, memberId],
				value: {
					room_code: code,
					user_id: userId,
					presence_id: userId,
					name: DEMO_NAMES[memberIndex],
					color: colorForIndex(memberIndex + 1),
					role: "member",
				},
			});

			let left = budget;
			let cursor = memberIndex;
			while (left > 0) {
				const cardId = cardIds[cursor % cardIds.length];
				const existing = ballots.find(
					(ballot) => ballot.userId === userId && ballot.cardId === cardId,
				);
				const current = existing?.count ?? 0;
				if (current >= maxPerCard) {
					cursor++;
					if (cursor > memberIndex + cards * 2) break;
					continue;
				}
				const take = Math.min(left, maxPerCard - current);
				if (existing) existing.count += take;
				else ballots.push({ userId, cardId, count: take });
				left -= take;
				cursor++;
			}
			operations.push({
				op: "set",
				path: [BUDGET_COLLECTION, memberId],
				value: {
					room_code: code,
					user_id: userId,
					votes_left: left,
				},
			});
		}

		for (const ballot of ballots) {
			operations.push({
				op: "set",
				path: [BALLOT_COLLECTION, client.utils.id()],
				value: {
					room_code: code,
					round,
					user_id: ballot.userId,
					card_id: ballot.cardId,
					count: ballot.count,
				},
			});
		}

		return {
			operations,
			members,
			cards,
			votes: ballots.reduce((sum, ballot) => sum + ballot.count, 0),
		};
	}

	await client.actions.handle("create_room", async (ctx, params) => {
		const existing = await roomByCode(code);
		if (existing)
			throw new ActionError("ROOM_EXISTS", "That room code is taken");

		const actor = actorId(ctx);
		const presence = ctx.userId;
		const template = isTemplate(params.template) ? params.template : "retro";
		const title = cleanTitle(params.title);
		const hostName = cleanName(params.name);
		const voteBudget = clampBudget(params.vote_budget);
		const maxPerCard = clampPerCard(params.max_per_card, voteBudget);
		const lanes = lanesFor(template);
		const demo = params.demo === true;
		const roomId = client.utils.id();
		const memberId = client.utils.id();
		const demoData = demo
			? demoOperations(code, 1, voteBudget, maxPerCard, lanes)
			: null;

		const operations: BatchOperation[] = [
			{
				op: "set",
				path: [ROOM_COLLECTION, roomId],
				value: {
					room_code: code,
					title,
					template,
					phase: "collect",
					round: 1,
					host_user_id: actor,
					vote_budget: voteBudget,
					max_per_card: maxPerCard,
					max_cards: MAX_CARDS,
					max_members: MAX_MEMBERS,
					members_count: 1 + (demoData?.members ?? 0),
					cards_count: demoData?.cards ?? 0,
					votes_cast: demoData?.votes ?? 0,
					votes_version: 0,
					results_count: 0,
					decisions_count: 0,
					vote_started_at: 0,
					vote_ends_at: 0,
					vote_closed_at: 0,
					focus_card_id: "",
					demo,
				},
			},
			{
				op: "set",
				path: [MEMBER_COLLECTION, memberId],
				value: {
					room_code: code,
					user_id: actor,
					presence_id: presence,
					name: cleanName(hostName),
					color: colorForIndex(0),
					role: "host",
				},
			},
			{
				op: "set",
				path: [BUDGET_COLLECTION, memberId],
				value: {
					room_code: code,
					user_id: actor,
					votes_left: voteBudget,
				},
			},
		];
		if (demoData) operations.push(...demoData.operations);

		try {
			await client.store.batch(operations, { confirm: "committed" });
		} catch (error) {
			if (isUnique(error)) {
				throw new ActionError("ROOM_EXISTS", "That room code is taken");
			}
			console.error(
				"create_room failed",
				error instanceof ZyncBaseError ? error.details : undefined,
				error,
			);
			throw error;
		}

		return {
			room_id: roomId,
			member_id: memberId,
			user_id: actor,
			presence_id: presence,
		};
	});

	await client.actions.handle("join_room", async (ctx, params) => {
		const room = await roomByCode(code);
		if (!room)
			throw new ActionError("ROOM_NOT_FOUND", "That room does not exist");

		const actor = actorId(ctx);
		const presence = ctx.userId;
		const existing = await memberByUser(code, actor);
		if (existing) {
			return {
				room_id: room.id,
				member_id: existing.id,
				user_id: actor,
				presence_id: presence,
				read_only: room.phase === "closed",
			};
		}
		if (isReadOnlyPhase(room.phase)) {
			return {
				room_id: room.id,
				member_id: "",
				user_id: actor,
				presence_id: presence,
				read_only: true,
			};
		}

		const name = cleanName(params.name);
		const memberId = client.utils.id();
		try {
			await client.store.batch(
				[
					{
						op: "set",
						path: [MEMBER_COLLECTION, memberId],
						value: {
							room_code: code,
							user_id: actor,
							presence_id: presence,
							name,
							color: colorForIndex(room.members_count),
							role: "member",
						},
					},
					{
						op: "set",
						path: [BUDGET_COLLECTION, memberId],
						value: {
							room_code: code,
							user_id: actor,
							votes_left: room.vote_budget,
						},
					},
					{
						op: "increment",
						path: [ROOM_COLLECTION, room.id, "members_count"],
						by: 1,
						if: {
							members_count: { lt: room.max_members },
							phase: { in: ["collect", "vote"] },
						},
					},
				],
				{ confirm: "committed" },
			);
		} catch (error) {
			if (isUnique(error)) {
				const raced = await memberByUser(code, actor);
				if (raced) {
					return {
						room_id: room.id,
						member_id: raced.id,
						user_id: actor,
						presence_id: presence,
						read_only: false,
					};
				}
			}
			if (isPrecondition(error)) {
				const fresh = await roomByCode(code);
				if (fresh && isReadOnlyPhase(fresh.phase)) {
					return {
						room_id: fresh.id,
						member_id: "",
						user_id: actor,
						presence_id: presence,
						read_only: true,
					};
				}
				if (!fresh) {
					throw new ActionError("ROOM_NOT_FOUND", "That room does not exist");
				}
				throw new ActionError("ROOM_FULL", "This room is full");
			}
			throw error;
		}

		const fresh = await roomByCode(code);
		if (fresh?.phase === "vote") {
			const cards = await allCards(code, fresh.round);
			await ensureBallots(
				code,
				fresh.round,
				[actor],
				cards.map((card) => card.id),
			);
		}
		return {
			room_id: room.id,
			member_id: memberId,
			user_id: actor,
			presence_id: presence,
			read_only: false,
		};
	});

	await client.actions.handle("add_card", async (ctx, params) => {
		const room = await roomByCode(code);
		if (!room)
			throw new ActionError("ROOM_NOT_FOUND", "That room does not exist");
		requirePhase(room, "collect");
		const member = await memberByUser(code, actorId(ctx));
		if (!member) throw new ActionError("NOT_A_MEMBER", "Join the room first");

		const lane = String(params.lane);
		if (!lanesFor(room.template).includes(lane)) {
			throw new ActionError("INVALID_LANE", "Unknown lane");
		}
		const text = cleanCard(params.text);
		const cardId = client.utils.id();
		try {
			await client.store.batch(
				[
					{
						op: "set",
						path: [CARD_COLLECTION, cardId],
						value: { room_code: code, round: room.round, lane, text },
					},
					{
						op: "increment",
						path: [ROOM_COLLECTION, room.id, "cards_count"],
						by: 1,
						if: {
							phase: { eq: "collect" },
							cards_count: { lt: room.max_cards },
						},
					},
				],
				{ confirm: "committed" },
			);
		} catch (error) {
			if (isPrecondition(error)) {
				const fresh = await roomByCode(code);
				if (fresh && fresh.phase !== "collect") throw phaseError(fresh);
				throw new ActionError("CARD_LIMIT", "This room has too many ideas");
			}
			throw error;
		}
		return { card_id: cardId };
	});

	await client.actions.handle("remove_card", async (ctx, params) => {
		const room = await roomByCode(code);
		if (!room)
			throw new ActionError("ROOM_NOT_FOUND", "That room does not exist");
		requireHost(room, ctx);
		requirePhase(room, "collect");
		const card = await cardFor(code, String(params.card_id));
		if (!card) throw new ActionError("CARD_NOT_FOUND", "That idea is gone");
		const existingBallots = await client.store.query(BALLOT_COLLECTION, {
			where: { room_code: code, round: room.round, card_id: card.id },
			limit: 1,
		});
		if ((existingBallots[0]?.count ?? 0) > 0) {
			throw new ActionError(
				"CARD_HAS_VOTES",
				"This idea already has votes and cannot be removed",
			);
		}
		try {
			await client.store.batch(
				[
					{
						op: "remove",
						path: [CARD_COLLECTION, card.id],
						if: { room_code: { eq: code } },
					},
					{
						op: "increment",
						path: [ROOM_COLLECTION, room.id, "cards_count"],
						by: -1,
						if: {
							phase: { eq: "collect" },
							cards_count: { gte: 1 },
						},
					},
				],
				{ confirm: "committed" },
			);
		} catch (error) {
			if (isPrecondition(error)) {
				const fresh = await roomByCode(code);
				if (fresh && fresh.phase !== "collect") throw phaseError(fresh);
				throw new ActionError("CARD_NOT_FOUND", "That idea is gone");
			}
			throw error;
		}
		return { ok: true };
	});

	await client.actions.handle("start_vote", async (ctx, params) => {
		const room = await roomByCode(code);
		if (!room)
			throw new ActionError("ROOM_NOT_FOUND", "That room does not exist");
		requireHost(room, ctx);
		requirePhase(room, "collect");
		if (room.cards_count < 1) {
			throw new ActionError("EMPTY_ROOM", "Add an idea before voting");
		}
		const [members, cards] = await Promise.all([
			allMembers(code),
			allCards(code, room.round),
		]);
		await ensureBallots(
			code,
			room.round,
			members.map((member) => member.user_id),
			cards.map((card) => card.id),
		);
		const now = Date.now();
		const endsAt = now + clampDuration(params.duration_ms);
		try {
			await client.store.batch(
				[
					{
						op: "set",
						path: [ROOM_COLLECTION, room.id, "vote_started_at"],
						value: now,
					},
					{
						op: "set",
						path: [ROOM_COLLECTION, room.id, "vote_ends_at"],
						value: endsAt,
					},
					{
						op: "set",
						path: [ROOM_COLLECTION, room.id, "phase"],
						value: "vote",
						if: { phase: { eq: "collect" }, cards_count: { gt: 0 } },
					},
				],
				{ confirm: "committed" },
			);
		} catch (error) {
			if (isPrecondition(error)) {
				const fresh = await roomByCode(code);
				if (fresh) throw phaseError(fresh);
			}
			throw error;
		}
		return { vote_ends_at: endsAt };
	});

	await client.actions.handle("extend_vote", async (ctx, params) => {
		for (let attempt = 0; attempt < 4; attempt++) {
			const room = await roomByCode(code);
			if (!room)
				throw new ActionError("ROOM_NOT_FOUND", "That room does not exist");
			requireHost(room, ctx);
			if (room.phase !== "vote") throw phaseError(room);
			const observed = room.vote_ends_at ?? 0;
			const now = Date.now();
			const endsAt =
				Math.max(observed, now) + clampDuration(params.duration_ms);
			try {
				await client.store.set(
					[ROOM_COLLECTION, room.id, "vote_ends_at"],
					endsAt,
					{
						confirm: "committed",
						if: { phase: { eq: "vote" }, vote_ends_at: { eq: observed } },
					},
				);
				return { vote_ends_at: endsAt };
			} catch (error) {
				if (!isPrecondition(error)) throw error;
			}
		}
		throw new ActionError(
			"EXTEND_CONFLICT",
			"The vote deadline changed; try again",
		);
	});

	await client.actions.handle("cast_vote", async (ctx, params) => {
		const room = await roomByCode(code);
		if (!room)
			throw new ActionError("ROOM_NOT_FOUND", "That room does not exist");
		requirePhase(room, "vote");
		const actor = actorId(ctx);
		const cardId = String(params.card_id);
		const card = await cardFor(code, cardId);
		if (!card) throw new ActionError("CARD_NOT_FOUND", "That idea is gone");

		const budget = await budgetFor(code, actor);
		if (!budget) throw new ActionError("NOT_A_MEMBER", "Join the room first");
		if (budget.votes_left < 1) {
			throw new ActionError("NO_VOTES_LEFT", "You have used all your votes");
		}
		let ballot = await ballotFor(code, room.round, actor, cardId);
		if (ballot && ballot.count >= room.max_per_card) {
			throw new ActionError(
				"CARD_LIMIT",
				`You can put at most ${room.max_per_card} votes on one idea`,
			);
		}
		if (!ballot) {
			const ballotId = client.utils.id();
			let created = false;
			try {
				await client.store.set(
					[BALLOT_COLLECTION, ballotId],
					{
						room_code: code,
						round: room.round,
						user_id: actor,
						card_id: cardId,
						count: 0,
					},
					{ confirm: "committed" },
				);
				created = true;
			} catch (error) {
				if (!isUnique(error)) {
					console.error("ballot bootstrap failed", error);
					throw error;
				}
			}
			if (created) {
				ballot = {
					id: ballotId,
					room_code: code,
					round: room.round,
					user_id: actor,
					card_id: cardId,
					count: 0,
				};
			} else {
				for (let attempt = 0; attempt < 5 && !ballot; attempt++) {
					ballot = await ballotFor(code, room.round, actor, cardId);
					if (!ballot) await sleep(25);
				}
				if (!ballot) {
					throw new ActionError("VOTE_FAILED", "Could not start your ballot");
				}
			}
		}

		try {
			await client.store.batch(
				[
					{
						op: "increment",
						path: [BALLOT_COLLECTION, ballot.id, "count"],
						by: 1,
						if: { count: { lt: room.max_per_card } },
					},
					{
						op: "increment",
						path: [BUDGET_COLLECTION, budget.id, "votes_left"],
						by: -1,
						if: { votes_left: { gte: 1 } },
					},
					{
						op: "increment",
						path: [ROOM_COLLECTION, room.id, "votes_cast"],
						by: 1,
						if: { phase: { eq: "vote" } },
					},
					{
						op: "increment",
						path: [ROOM_COLLECTION, room.id, "votes_version"],
						by: 1,
						if: { phase: { eq: "vote" } },
					},
				],
				{ confirm: "committed" },
			);
		} catch (error) {
			if (isPrecondition(error)) {
				const fresh = await roomByCode(code);
				if (fresh && fresh.phase !== "vote") throw phaseError(fresh);
				throw new ActionError(
					"VOTE_REJECTED",
					"No votes left, or that idea is already at its limit",
				);
			}
			console.error("cast_vote failed", error);
			throw error;
		}

		const [currentBudget, currentBallot] = await Promise.all([
			budgetFor(code, actorId(ctx)),
			ballotFor(code, room.round, actorId(ctx), cardId),
		]);
		return {
			votes_left: currentBudget?.votes_left ?? 0,
			card_votes: currentBallot?.count ?? 0,
		};
	});

	await client.actions.handle("retract_vote", async (ctx, params) => {
		const room = await roomByCode(code);
		if (!room)
			throw new ActionError("ROOM_NOT_FOUND", "That room does not exist");
		requirePhase(room, "vote");
		const cardId = String(params.card_id);
		const budget = await budgetFor(code, actorId(ctx));
		if (!budget) throw new ActionError("NOT_A_MEMBER", "Join the room first");
		const ballot = await ballotFor(code, room.round, actorId(ctx), cardId);
		if (!ballot || ballot.count < 1) {
			throw new ActionError("NO_VOTE", "You have not voted for that idea");
		}
		try {
			await client.store.batch(
				[
					{
						op: "increment",
						path: [BALLOT_COLLECTION, ballot.id, "count"],
						by: -1,
						if: { count: { gte: 1 } },
					},
					{
						op: "increment",
						path: [BUDGET_COLLECTION, budget.id, "votes_left"],
						by: 1,
					},
					{
						op: "increment",
						path: [ROOM_COLLECTION, room.id, "votes_cast"],
						by: -1,
						if: { phase: { eq: "vote" }, votes_cast: { gte: 1 } },
					},
					{
						op: "increment",
						path: [ROOM_COLLECTION, room.id, "votes_version"],
						by: 1,
						if: { phase: { eq: "vote" } },
					},
				],
				{ confirm: "committed" },
			);
		} catch (error) {
			if (isPrecondition(error)) {
				const fresh = await roomByCode(code);
				if (fresh && fresh.phase !== "vote") throw phaseError(fresh);
				throw new ActionError(
					"VOTE_REJECTED",
					"That vote could not be retracted",
				);
			}
			throw error;
		}
		const [currentBudget, currentBallot] = await Promise.all([
			budgetFor(code, actorId(ctx)),
			ballotFor(code, room.round, actorId(ctx), cardId),
		]);
		return {
			votes_left: currentBudget?.votes_left ?? 0,
			card_votes: currentBallot?.count ?? 0,
		};
	});

	await client.actions.handle("close_vote", async (ctx, _params) => {
		const room = await roomByCode(code);
		if (!room)
			throw new ActionError("ROOM_NOT_FOUND", "That room does not exist");
		requireHost(room, ctx);
		if (room.phase === "results") {
			return { closed: true, results_count: room.results_count };
		}
		requirePhase(room, "vote");

		for (let attempt = 0; attempt < 4; attempt++) {
			const current = await roomByCode(code);
			if (!current)
				throw new ActionError("ROOM_NOT_FOUND", "That room does not exist");
			if (current.phase === "results") {
				return { closed: true, results_count: current.results_count };
			}
			requirePhase(current, "vote");
			const version = current.votes_version;
			const [cards, ballots] = await Promise.all([
				allCards(code, current.round),
				allBallots(code, current.round),
			]);
			const tallies = new Map<string, number>();
			let total = 0;
			for (const ballot of ballots) {
				if (ballot.count < 1) continue;
				tallies.set(
					ballot.card_id,
					(tallies.get(ballot.card_id) ?? 0) + ballot.count,
				);
				total += ballot.count;
			}
			// A concurrent vote/retract makes this read inconsistent; retry.
			if (total !== current.votes_cast) continue;

			const ranked = cards
				.map((card) => ({
					card,
					votes: tallies.get(card.id) ?? 0,
				}))
				.sort((a, b) => {
					if (b.votes !== a.votes) return b.votes - a.votes;
					return a.card.id < b.card.id ? -1 : a.card.id > b.card.id ? 1 : 0;
				});
			const focusCardId = ranked[0]?.card.id ?? "";
			// The phase guard goes first. A concurrent close would otherwise
			// insert the same result rows and fail the unique constraint before
			// reaching the CAS that is supposed to make this idempotent.
			const resultOperations: BatchOperation[] = [
				{
					op: "set",
					path: [ROOM_COLLECTION, current.id, "vote_closed_at"],
					value: Date.now(),
				},
				{
					op: "set",
					path: [ROOM_COLLECTION, current.id, "results_count"],
					value: ranked.length,
				},
				{
					op: "set",
					path: [ROOM_COLLECTION, current.id, "focus_card_id"],
					value: focusCardId,
				},
				{
					op: "set",
					path: [ROOM_COLLECTION, current.id, "phase"],
					value: "results",
					if: {
						phase: { eq: "vote" },
						votes_version: { eq: version },
					},
				},
				...ranked.map((entry, index) => ({
					op: "set" as const,
					path: [RESULT_COLLECTION, client.utils.id()],
					value: {
						room_code: code,
						round: current.round,
						card_id: entry.card.id,
						lane: entry.card.lane,
						text: entry.card.text,
						votes: entry.votes,
						rank: index + 1,
					},
				})),
			];
			try {
				await client.store.batch(resultOperations, { confirm: "committed" });
				return { closed: true, results_count: ranked.length };
			} catch (error) {
				if (isPrecondition(error)) continue;
				throw error;
			}
		}
		throw new ActionError(
			"LEDGER_MISMATCH",
			"The vote changed repeatedly while closing; try again",
		);
	});

	await client.actions.handle("start_discussion", async (ctx, _params) => {
		const room = await roomByCode(code);
		if (!room)
			throw new ActionError("ROOM_NOT_FOUND", "That room does not exist");
		requireHost(room, ctx);
		requirePhase(room, "results");
		const results = await allResults(code, room.round);
		const focus = results[0]?.card_id ?? "";
		try {
			await client.store.batch(
				[
					{
						op: "set",
						path: [ROOM_COLLECTION, room.id, "focus_card_id"],
						value: focus,
					},
					{
						op: "set",
						path: [ROOM_COLLECTION, room.id, "phase"],
						value: "discuss",
						if: { phase: { eq: "results" } },
					},
				],
				{ confirm: "committed" },
			);
		} catch (error) {
			if (isPrecondition(error)) {
				const fresh = await roomByCode(code);
				if (fresh) throw phaseError(fresh);
			}
			throw error;
		}
		return { focus_card_id: focus };
	});

	await client.actions.handle("focus_topic", async (ctx, params) => {
		const room = await roomByCode(code);
		if (!room)
			throw new ActionError("ROOM_NOT_FOUND", "That room does not exist");
		requireHost(room, ctx);
		requirePhase(room, "discuss");
		const cardId = String(params.card_id);
		const rows = await client.store.query(RESULT_COLLECTION, {
			where: { room_code: code, round: room.round, card_id: cardId },
			limit: 1,
		});
		if (rows.length === 0) {
			throw new ActionError(
				"RESULT_NOT_FOUND",
				"That topic is not in the results",
			);
		}
		try {
			await client.store.set(
				[ROOM_COLLECTION, room.id, "focus_card_id"],
				cardId,
				{ confirm: "committed", if: { phase: { eq: "discuss" } } },
			);
		} catch (error) {
			if (isPrecondition(error)) {
				const fresh = await roomByCode(code);
				if (fresh) throw phaseError(fresh);
			}
			throw error;
		}
		return { ok: true };
	});

	await client.actions.handle("add_decision", async (ctx, params) => {
		const room = await roomByCode(code);
		if (!room)
			throw new ActionError("ROOM_NOT_FOUND", "That room does not exist");
		requirePhase(room, "discuss");
		const member = await memberByUser(code, actorId(ctx));
		if (!member) throw new ActionError("NOT_A_MEMBER", "Join the room first");
		const text = cleanCard(params.text);
		const decisionId = client.utils.id();
		try {
			await client.store.batch(
				[
					{
						op: "set",
						path: [DECISION_COLLECTION, decisionId],
						value: {
							room_code: code,
							round: room.round,
							card_id: room.focus_card_id ?? "",
							text,
							author_name: member.name,
						},
					},
					{
						op: "increment",
						path: [ROOM_COLLECTION, room.id, "decisions_count"],
						by: 1,
						if: { phase: { eq: "discuss" } },
					},
				],
				{ confirm: "committed" },
			);
		} catch (error) {
			if (isPrecondition(error)) {
				const fresh = await roomByCode(code);
				if (fresh) throw phaseError(fresh);
			}
			throw error;
		}
		return { decision_id: decisionId };
	});

	await client.actions.handle("close_room", async (ctx, _params) => {
		const room = await roomByCode(code);
		if (!room)
			throw new ActionError("ROOM_NOT_FOUND", "That room does not exist");
		requireHost(room, ctx);
		try {
			await client.store.set([ROOM_COLLECTION, room.id, "phase"], "closed", {
				confirm: "committed",
				if: { phase: { in: ["results", "discuss"] } },
			});
		} catch (error) {
			if (isPrecondition(error)) {
				const fresh = await roomByCode(code);
				if (fresh) throw phaseError(fresh);
			}
			throw error;
		}
		return { ok: true };
	});

	return {
		client,
		stop: async () => {
			await client.disconnect();
		},
	};
}
