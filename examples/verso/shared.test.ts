import { describe, expect, test } from "bun:test";
import { relativeTime, type UserRow, userOf } from "./shared";

function user(id: string, name: string): UserRow {
	return { id, name, color: "#c96a4b" };
}

describe("people lookup", () => {
	const people = new Map([["u1", user("u1", "Ada")]]);

	test("finds the profile behind an owner id", () => {
		expect(userOf("u1", people)?.name).toBe("Ada");
	});

	test("unknown or absent owners have no profile", () => {
		expect(userOf("u2", people)).toBeUndefined();
		expect(userOf(undefined, people)).toBeUndefined();
	});
});

describe("relative time", () => {
	const micro = (msAgo: number) => (Date.now() - msAgo) * 1000;

	test("near timestamps read as just now", () => {
		expect(relativeTime(micro(10_000))).toBe("just now");
	});

	test("older timestamps pick the matching unit", () => {
		expect(relativeTime(micro(5 * 60_000))).toBe("5 minutes ago");
		expect(relativeTime(micro(3 * 3_600_000))).toBe("3 hours ago");
		expect(relativeTime(micro(3 * 86_400_000))).toBe("3 days ago");
	});
});
