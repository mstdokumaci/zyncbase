import { createClient } from "@zyncbase/client";
import {
	type AppClient,
	COLORS,
	cleanText,
	type Identity,
	STORE_NAMESPACE,
} from "./shared";

/**
 * Identity is claimed, not verified: the server mints a token for whatever
 * email you type. The token lives in sessionStorage, so two tabs in one browser
 * can be two different people. Swap this for passwordless login and nothing
 * else in the app changes.
 */
const IDENTITY_KEY = "verso:identity";

export interface VersoSession {
	client: AppClient;
	identity: Identity;
}

export function storedIdentity(): Identity | null {
	const raw = sessionStorage.getItem(IDENTITY_KEY);
	if (!raw) return null;
	try {
		const value = JSON.parse(raw) as Partial<Identity>;
		if (
			typeof value.email === "string" &&
			typeof value.name === "string" &&
			typeof value.color === "string"
		) {
			return { email: value.email, name: value.name, color: value.color };
		}
	} catch {}
	return null;
}

function websocketUrl(): string {
	const protocol = location.protocol === "https:" ? "wss:" : "ws:";
	return `${protocol}//${location.host}/ws`;
}

export async function joinWorkspace(input: Identity): Promise<VersoSession> {
	const email = input.email.trim().toLowerCase();
	const response = await fetch("/session", {
		method: "POST",
		headers: { "content-type": "application/json" },
		body: JSON.stringify({ email }),
	});
	const body = (await response.json().catch(() => ({}))) as {
		token?: string;
		error?: string;
	};
	if (!response.ok || !body.token) {
		throw new Error(body.error ?? "Could not start a session");
	}
	const identity: Identity = {
		email,
		name: cleanText(input.name, 64) || email.split("@")[0] || "Someone",
		color: input.color,
	};
	const client = createClient({
		url: websocketUrl(),
		auth: { token: body.token },
		storeNamespace: STORE_NAMESPACE,
		presenceNamespace: STORE_NAMESPACE,
	}) as AppClient;
	await client.connect();
	// The identity resolver already created the users row; fill in what the UI shows.
	const me = client.presence.localUserId;
	if (me) {
		await client.store
			.batch([
				{ op: "set", path: ["users", me, "name"], value: identity.name },
				{ op: "set", path: ["users", me, "color"], value: identity.color },
			])
			.catch((error: unknown) => console.warn("Profile write failed", error));
	}
	sessionStorage.setItem(IDENTITY_KEY, JSON.stringify(identity));
	return { client, identity };
}

export function leaveWorkspace(session: VersoSession): void {
	sessionStorage.removeItem(IDENTITY_KEY);
	session.client.disconnect();
}

export function fallbackColor(): string {
	return COLORS[Math.floor(Math.random() * COLORS.length)] ?? "#c96a4b";
}
