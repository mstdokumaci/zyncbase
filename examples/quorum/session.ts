// biome-ignore-all lint/complexity/noExcessiveCognitiveComplexity: token exchange and credential retry form one linear session flow.
import { createClient } from "@zyncbase/client";
import type {
	ZyncBaseActions,
	ZyncBasePresence,
	ZyncBaseSchema,
} from "./schema-types";
import type { AppClient } from "./shared";
import { roomNamespace } from "./shared";

const CREDENTIAL_KEY = "quorum:credential";
const CREDENTIAL_COOKIE = "quorum_credential";
const CREDENTIAL_COOKIE_MAX_AGE = 31_536_000;
const NAME_KEY = "quorum:name";

let memoryCredential: string | null = null;
let connectAttempts = 0;

function storageGet(key: string): string | null {
	try {
		return localStorage.getItem(key);
	} catch {
		return null;
	}
}

function storageSet(key: string, value: string): void {
	try {
		localStorage.setItem(key, value);
	} catch {}
}

function storageRemove(key: string): void {
	try {
		localStorage.removeItem(key);
	} catch {}
}

function readCredentialCookie(): string | null {
	if (typeof document === "undefined") return null;
	try {
		const prefix = `${CREDENTIAL_COOKIE}=`;
		for (const part of document.cookie.split("; ")) {
			if (part.startsWith(prefix)) {
				return decodeURIComponent(part.slice(prefix.length));
			}
		}
	} catch {}
	return null;
}

function writeCredentialCookie(value: string | null): void {
	if (typeof document === "undefined") return;
	try {
		// biome-ignore lint/suspicious/noDocumentCookie: Cookie Store is async and not available in every browser; this is the synchronous fallback.
		document.cookie = `${CREDENTIAL_COOKIE}=${value ? encodeURIComponent(value) : ""}; Path=/; SameSite=Lax; Max-Age=${value ? CREDENTIAL_COOKIE_MAX_AGE : 0}`;
	} catch {}
}

function storedCredential(): string | null {
	if (memoryCredential) return memoryCredential;
	const stored = storageGet(CREDENTIAL_KEY);
	if (stored) {
		memoryCredential = stored;
		return memoryCredential;
	}
	const cookie = readCredentialCookie();
	if (cookie) memoryCredential = cookie;
	return memoryCredential;
}

function rememberCredential(credential: string): void {
	memoryCredential = credential;
	storageSet(CREDENTIAL_KEY, credential);
	writeCredentialCookie(credential);
}

function forgetCredential(): void {
	memoryCredential = null;
	storageRemove(CREDENTIAL_KEY);
	writeCredentialCookie(null);
}

export function savedName(): string {
	return storageGet(NAME_KEY) ?? "";
}

export function saveName(name: string): void {
	storageSet(NAME_KEY, name);
}

export interface RoomSession {
	client: AppClient;
	code: string;
	roomId: string;
	memberId: string;
	userId: string;
	presenceId: string;
	readOnly: boolean;
	name: string;
}

function websocketUrl(): string {
	const protocol = location.protocol === "https:" ? "wss:" : "ws:";
	return `${protocol}//${location.host}/ws`;
}

export async function connectRoom(code: string): Promise<AppClient> {
	const connectionAttempt = ++connectAttempts;
	const tokenProvider = async (): Promise<string> => {
		for (let retry = 0; retry < 2; retry++) {
			const credential = storedCredential();
			const response = await fetch("/session", {
				method: "POST",
				headers: { "content-type": "application/json" },
				body: JSON.stringify({
					room: code,
					...(credential ? { credential } : {}),
				}),
			});
			if (response.status === 401 && credential) {
				if (connectionAttempt === connectAttempts) forgetCredential();
				continue;
			}
			if (!response.ok) {
				let message = "Could not start the room";
				try {
					const body = (await response.json()) as { error?: string };
					if (body.error) message = body.error;
				} catch {}
				throw new Error(message);
			}
			const body = (await response.json()) as {
				token?: string;
				credential?: string;
			};
			if (body.credential && connectionAttempt === connectAttempts) {
				rememberCredential(body.credential);
			}
			if (!body.token) throw new Error("The room returned no session");
			return body.token;
		}
		throw new Error("Could not start the room");
	};

	const client = createClient<
		ZyncBaseSchema,
		ZyncBaseActions,
		ZyncBasePresence
	>({
		url: websocketUrl(),
		auth: { tokenProvider },
		storeNamespace: roomNamespace(code),
		presenceNamespace: roomNamespace(code),
	});
	let timeout: ReturnType<typeof setTimeout> | undefined;
	try {
		await Promise.race([
			client.connect(),
			new Promise<never>((_, reject) => {
				timeout = setTimeout(
					() => reject(new Error("The room took too long to connect")),
					15_000,
				);
			}),
		]);
		return client;
	} catch (error) {
		client.disconnect();
		throw error;
	} finally {
		if (timeout) clearTimeout(timeout);
	}
}
