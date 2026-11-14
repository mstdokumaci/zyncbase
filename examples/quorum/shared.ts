import type { DocumentRowOf, ZyncBaseClient } from "@zyncbase/client";
import type {
	ZyncBaseActions,
	ZyncBasePresence,
	ZyncBaseSchema,
} from "./schema-types";

/** The app's client bound to its generated schema, actions, and presence. */
export type AppClient = ZyncBaseClient<
	ZyncBaseSchema,
	ZyncBaseActions,
	ZyncBasePresence
>;

export type RoomRow = DocumentRowOf<ZyncBaseSchema, "rooms">;
export type MemberRow = DocumentRowOf<ZyncBaseSchema, "members">;
export type BudgetRow = DocumentRowOf<ZyncBaseSchema, "budgets">;
export type CardRow = DocumentRowOf<ZyncBaseSchema, "cards">;
export type BallotRow = DocumentRowOf<ZyncBaseSchema, "ballots">;
export type ResultRow = DocumentRowOf<ZyncBaseSchema, "results">;
export type DecisionRow = DocumentRowOf<ZyncBaseSchema, "decisions">;
export type PresenceUser = ZyncBasePresence["user"];

export const ROOM_NAMESPACE_PREFIX = "room:";
export const ROOM_CODE_LENGTH = 8;
export const ROOM_CODE_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";
export const MAX_NAME_LENGTH = 24;
export const MAX_TITLE_LENGTH = 80;
export const MAX_CARD_LENGTH = 280;
export const MAX_CARDS = 100;
export const MAX_MEMBERS = 50;
export const DEFAULT_VOTE_BUDGET = 5;
export const DEFAULT_MAX_PER_CARD = 3;
export const DEFAULT_VOTE_DURATION_MS = 5 * 60_000;
export const MIN_VOTE_DURATION_MS = 60_000;
export const MAX_VOTE_DURATION_MS = 60 * 60_000;

export const TEMPLATES = {
	retro: { label: "Retro", lanes: ["Start", "Stop", "Continue"] },
	list: { label: "Prioritize", lanes: ["Ideas"] },
} as const;

export type TemplateId = keyof typeof TEMPLATES;

export const PHASES = [
	{ id: "collect", label: "Collect" },
	{ id: "vote", label: "Vote" },
	{ id: "results", label: "Results" },
	{ id: "discuss", label: "Discuss" },
	{ id: "closed", label: "Summary" },
] as const;

export const COLORS = [
	"#e05d44",
	"#2f80ed",
	"#27ae60",
	"#9b51e0",
	"#f2994a",
	"#eb5757",
	"#00a3a3",
	"#b28b00",
	"#6b7c93",
	"#d94f8a",
	"#4f7a28",
	"#7b61ff",
] as const;

export function roomNamespace(code: string): string {
	return `${ROOM_NAMESPACE_PREFIX}${code}`;
}

export function isTemplate(value: string): value is TemplateId {
	return Object.hasOwn(TEMPLATES, value);
}

export function lanesFor(template: TemplateId): readonly string[] {
	return TEMPLATES[template].lanes;
}

export function normalizeRoomCode(value: string): string {
	return value.trim().toLowerCase();
}

export function isRoomCode(value: string): boolean {
	return (
		value.length >= 6 &&
		value.length <= 12 &&
		[...value].every((char) => ROOM_CODE_ALPHABET.includes(char))
	);
}

export function generateRoomCode(): string {
	const bytes = new Uint8Array(ROOM_CODE_LENGTH);
	crypto.getRandomValues(bytes);
	let code = "";
	for (const byte of bytes) {
		code += ROOM_CODE_ALPHABET[byte % ROOM_CODE_ALPHABET.length];
	}
	return code;
}

export function colorForIndex(index: number): string {
	return COLORS[index % COLORS.length];
}

export function initials(name: string): string {
	const parts = name.trim().split(/\s+/).filter(Boolean);
	if (parts.length === 0) return "?";
	if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
	return `${parts[0][0]}${parts[parts.length - 1][0]}`.toUpperCase();
}

export function clampName(value: string): string {
	return value.trim().slice(0, MAX_NAME_LENGTH);
}

export function clampTitle(value: string): string {
	return value.trim().slice(0, MAX_TITLE_LENGTH);
}

export function clampCard(value: string): string {
	return value.trim().slice(0, MAX_CARD_LENGTH);
}

/** Total possible votes for a room, including sample members in the demo. */
export function possibleVotes(room: RoomRow): number {
	return room.members_count * room.vote_budget;
}

export function isHost(room: RoomRow, userId: string | null): boolean {
	return userId !== null && room.host_user_id === userId;
}

export function isReadOnlyPhase(phase: RoomRow["phase"]): boolean {
	return phase === "results" || phase === "discuss" || phase === "closed";
}
