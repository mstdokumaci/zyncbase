import { describe, expect, test } from "bun:test";
import {
	clampCard,
	clampName,
	clampTitle,
	colorForIndex,
	generateRoomCode,
	initials,
	isHost,
	isRoomCode,
	lanesFor,
	normalizeRoomCode,
	possibleVotes,
	ROOM_CODE_ALPHABET,
	ROOM_CODE_LENGTH,
	type RoomRow,
	roomNamespace,
} from "./shared";

describe("room codes", () => {
	test("generates the documented alphabet and length", () => {
		for (let index = 0; index < 100; index++) {
			const code = generateRoomCode();
			expect(code).toHaveLength(ROOM_CODE_LENGTH);
			expect([...code].every((char) => ROOM_CODE_ALPHABET.includes(char))).toBe(
				true,
			);
			expect(isRoomCode(code)).toBe(true);
		}
	});

	test("normalizes case and whitespace", () => {
		expect(normalizeRoomCode("  ABC123xy ")).toBe("abc123xy");
	});

	test("rejects invalid codes", () => {
		expect(isRoomCode("short")).toBe(false);
		expect(isRoomCode("has space")).toBe(false);
		expect(isRoomCode("UPPERCASE")).toBe(false);
	});
});

describe("templates and limits", () => {
	test("retro lanes and namespace", () => {
		expect(lanesFor("retro")).toEqual(["Start", "Stop", "Continue"]);
		expect(lanesFor("list")).toEqual(["Ideas"]);
		expect(roomNamespace("k3m9x2qp")).toBe("room:k3m9x2qp");
	});

	test("clamps text to schema limits", () => {
		expect(clampName("  Ada  ")).toBe("Ada");
		expect(clampTitle("x".repeat(100))).toHaveLength(80);
		expect(clampCard("x".repeat(300))).toHaveLength(280);
	});

	test("computes possible votes and host", () => {
		const room = {
			members_count: 4,
			vote_budget: 5,
			host_user_id: "u:host",
		} as RoomRow;
		expect(possibleVotes(room)).toBe(20);
		expect(isHost(room, "u:host")).toBe(true);
		expect(isHost(room, null)).toBe(false);
	});

	test("initials and palette are stable", () => {
		expect(initials("Ada Lovelace")).toBe("AL");
		expect(initials("Ada")).toBe("AD");
		expect(initials("")).toBe("?");
		expect(colorForIndex(0)).toBe(colorForIndex(12));
	});
});
