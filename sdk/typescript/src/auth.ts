import { getOrCreateAnonymousSubject } from "./anonymous.js";
import { ErrorCodes, ZyncBaseError } from "./errors.js";
import type { AuthConfig, TicketResponse } from "./types.js";

const httpBaseCache = new Map<string, string>();

export function deriveHttpBase(wsUrl: string): string {
	const cached = httpBaseCache.get(wsUrl);
	if (cached) return cached;

	const url = new URL(wsUrl);
	url.protocol = url.protocol === "wss:" ? "https:" : "http:";
	url.pathname = "";
	url.search = "";
	url.hash = "";
	const result = url.toString().replace(/\/$/, "");
	httpBaseCache.set(wsUrl, result);
	return result;
}

async function resolveToken(auth: AuthConfig): Promise<string> {
	if ("tokenProvider" in auth) {
		return await auth.tokenProvider();
	}
	if ("token" in auth) {
		return auth.token;
	}
	throw new ZyncBaseError(
		"Invalid auth configuration: missing token or tokenProvider",
		{
			code: ErrorCodes.AUTH_FAILED,
			category: "auth",
			retryable: false,
		},
	);
}

function buildFetchRequest(
	endpoint: string,
	auth: AuthConfig,
): Promise<Response> {
	if ("anonymous" in auth && auth.anonymous) {
		const anonymousSubject = getOrCreateAnonymousSubject();
		const body = JSON.stringify({ anonymousSubject });
		return fetch(endpoint, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body,
		});
	}
	return resolveToken(auth).then((token) =>
		fetch(endpoint, {
			method: "POST",
			headers: { Authorization: `Bearer ${token}` },
		}),
	);
}

async function parseTicketResponse(
	response: Response,
): Promise<TicketResponse> {
	if (!response.ok) {
		return parseErrorResponse(response);
	}
	let body: TicketResponse;
	try {
		body = (await response.json()) as TicketResponse;
	} catch {
		throw new ZyncBaseError("Failed to parse ticket response as JSON", {
			code: ErrorCodes.AUTH_FAILED,
			category: "auth",
			retryable: false,
		});
	}
	if (!body || typeof body !== "object" || !body.ticket) {
		throw new ZyncBaseError("Ticket response missing ticket field", {
			code: ErrorCodes.AUTH_FAILED,
			category: "auth",
			retryable: false,
		});
	}
	return body;
}

async function parseErrorResponse(response: Response): Promise<never> {
	let code: string = ErrorCodes.AUTH_FAILED;
	let message = "Ticket exchange failed";
	try {
		const body = (await response.json()) as {
			code?: string;
			message?: string;
		};
		if (body.code) code = body.code;
		if (body.message) message = body.message;
	} catch {}
	throw new ZyncBaseError(message, {
		code,
		category: "auth",
		retryable: false,
	});
}

export async function acquireTicket(
	wsUrl: string,
	auth: AuthConfig,
): Promise<TicketResponse> {
	const endpoint = `${deriveHttpBase(wsUrl)}/auth/ticket`;

	let response: Response;
	try {
		response = await buildFetchRequest(endpoint, auth);
	} catch (err) {
		if (err instanceof ZyncBaseError) {
			throw err;
		}
		throw new ZyncBaseError(
			err instanceof Error ? err.message : "Ticket request failed",
			{
				code: ErrorCodes.CONNECTION_FAILED,
				category: "network",
				retryable: true,
			},
		);
	}

	return parseTicketResponse(response);
}
