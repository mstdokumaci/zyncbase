import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { resetAnonymousSubject } from "./anonymous";
import { acquireTicket, deriveHttpBase } from "./auth";
import { ZyncBaseError } from "./errors";

const originalFetch = globalThis.fetch;

describe("deriveHttpBase", () => {
	test("converts ws:// to http://", () => {
		expect(deriveHttpBase("ws://localhost:3000")).toBe("http://localhost:3000");
	});

	test("converts wss:// to https://", () => {
		expect(deriveHttpBase("wss://example.com")).toBe("https://example.com");
	});

	test("strips path from URL", () => {
		expect(deriveHttpBase("ws://localhost:3000/ws")).toBe(
			"http://localhost:3000",
		);
	});

	test("strips query string from URL", () => {
		expect(deriveHttpBase("ws://localhost:3000?foo=bar")).toBe(
			"http://localhost:3000",
		);
	});
});

describe("acquireTicket", () => {
	let fetchCalls: Array<{ url: string; init: RequestInit }> = [];

	beforeEach(() => {
		fetchCalls = [];
		resetAnonymousSubject();
		(globalThis as Record<string, unknown>).fetch = async (
			input: RequestInfo | URL,
			init?: RequestInit,
		) => {
			const url = typeof input === "string" ? input : input.toString();
			fetchCalls.push({ url, init: init ?? {} });
			return new Response(
				JSON.stringify({ ticket: "zyc_tk_test", expiresAt: 9999999999 }),
				{
					status: 200,
					headers: { "Content-Type": "application/json" },
				},
			);
		};
	});

	afterEach(() => {
		(globalThis as Record<string, unknown>).fetch = originalFetch;
	});

	test("JWT mode sends Bearer token", async () => {
		await acquireTicket("ws://localhost:3000", { token: "my-jwt" });

		expect(fetchCalls).toHaveLength(1);
		expect(fetchCalls[0].url).toBe("http://localhost:3000/auth/ticket");
		expect(fetchCalls[0].init.method).toBe("POST");
		const headers = fetchCalls[0].init.headers as Record<string, string>;
		expect(headers.Authorization).toBe("Bearer my-jwt");
	});

	test("anonymous mode sends anonymousSubject in body", async () => {
		await acquireTicket("ws://localhost:3000", { anonymous: true });

		expect(fetchCalls).toHaveLength(1);
		expect(fetchCalls[0].url).toBe("http://localhost:3000/auth/ticket");
		expect(fetchCalls[0].init.method).toBe("POST");
		const headers = fetchCalls[0].init.headers as Record<string, string>;
		expect(headers["Content-Type"]).toBe("application/json");
		const body = JSON.parse(fetchCalls[0].init.body as string);
		expect(body.anonymousSubject).toMatch(/^anon:[0-9a-f]{64}$/);
	});

	test("tokenProvider mode calls provider and sends Bearer token", async () => {
		let callCount = 0;
		const provider = async () => {
			callCount++;
			return `dynamic-token-${callCount}`;
		};

		await acquireTicket("ws://localhost:3000", { tokenProvider: provider });
		expect(fetchCalls).toHaveLength(1);
		const headers1 = fetchCalls[0].init.headers as Record<string, string>;
		expect(headers1.Authorization).toBe("Bearer dynamic-token-1");

		await acquireTicket("ws://localhost:3000", { tokenProvider: provider });
		expect(fetchCalls).toHaveLength(2);
		const headers2 = fetchCalls[1].init.headers as Record<string, string>;
		expect(headers2.Authorization).toBe("Bearer dynamic-token-2");
	});

	test("returns ticket and expiresAt on success", async () => {
		const result = await acquireTicket("ws://localhost:3000", {
			anonymous: true,
		});
		expect(result.ticket).toBe("zyc_tk_test");
		expect(result.expiresAt).toBe(9999999999);
	});

	test("throws AUTH_FAILED on non-200 response", async () => {
		(globalThis as Record<string, unknown>).fetch = async () =>
			new Response(
				JSON.stringify({ code: "AUTH_FAILED", message: "Bad token" }),
				{
					status: 401,
					headers: { "Content-Type": "application/json" },
				},
			);

		await expect(
			acquireTicket("ws://localhost:3000", { token: "bad" }),
		).rejects.toMatchObject({
			code: "AUTH_FAILED",
			category: "auth",
		});
	});

	test("throws CONNECTION_FAILED on network error", async () => {
		(globalThis as Record<string, unknown>).fetch = async () => {
			throw new TypeError("Failed to fetch");
		};

		await expect(
			acquireTicket("ws://localhost:3000", { anonymous: true }),
		).rejects.toMatchObject({
			code: "CONNECTION_FAILED",
			category: "network",
			retryable: true,
		});
	});

	test("throws AUTH_FAILED when response is missing ticket field", async () => {
		(globalThis as Record<string, unknown>).fetch = async () =>
			new Response(JSON.stringify({ expiresAt: 123 }), {
				status: 200,
				headers: { "Content-Type": "application/json" },
			});

		await expect(
			acquireTicket("ws://localhost:3000", { anonymous: true }),
		).rejects.toBeInstanceOf(ZyncBaseError);
	});
});
