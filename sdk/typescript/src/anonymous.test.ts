import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import {
	getOrCreateAnonymousSubject,
	resetAnonymousSubject,
	resetInMemorySubject,
} from "./anonymous";

const ANON_PREFIX = "anon:";
const HEX_PATTERN = /^[0-9a-f]{64}$/;

describe("Anonymous Subject", () => {
	beforeEach(() => {
		resetAnonymousSubject();
		if (typeof localStorage !== "undefined") {
			localStorage.clear();
		}
	});

	afterEach(() => {
		resetAnonymousSubject();
	});

	test("generates subject with correct prefix", () => {
		const subject = getOrCreateAnonymousSubject();
		expect(subject.startsWith(ANON_PREFIX)).toBe(true);
	});

	test("generates 64-char hex suffix (32 bytes)", () => {
		const subject = getOrCreateAnonymousSubject();
		const hex = subject.slice(ANON_PREFIX.length);
		expect(hex).toMatch(HEX_PATTERN);
	});

	test("returns same subject on subsequent calls (in-memory)", () => {
		const first = getOrCreateAnonymousSubject();
		const second = getOrCreateAnonymousSubject();
		expect(first).toBe(second);
	});

	test("returns same subject from localStorage", () => {
		if (typeof localStorage === "undefined") {
			return;
		}
		const first = getOrCreateAnonymousSubject();
		resetInMemorySubject();
		const second = getOrCreateAnonymousSubject();
		expect(first).toBe(second);
	});

	test("resetAnonymousSubject generates a new subject", () => {
		const first = getOrCreateAnonymousSubject();
		resetAnonymousSubject();
		if (typeof localStorage !== "undefined") {
			localStorage.clear();
		}
		const second = getOrCreateAnonymousSubject();
		expect(first).not.toBe(second);
	});

	test("generated subjects are unique across resets", () => {
		const subjects = new Set<string>();
		for (let i = 0; i < 10; i++) {
			resetAnonymousSubject();
			if (typeof localStorage !== "undefined") {
				localStorage.clear();
			}
			subjects.add(getOrCreateAnonymousSubject());
		}
		expect(subjects.size).toBe(10);
	});
});
