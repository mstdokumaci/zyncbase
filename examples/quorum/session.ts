import { createClient } from "@zyncbase/client";
import type {
	ZyncBaseActions,
	ZyncBasePresence,
	ZyncBaseSchema,
} from "./schema-types";
import type { AppClient } from "./shared";
import { roomNamespace } from "./shared";

const SUBJECT_KEY = "quorum:subject";
const NAME_KEY = "quorum:name";

let memorySubject: string | null = null;

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

export function subject(): string {
	if (memorySubject) return memorySubject;
	const stored = storageGet(SUBJECT_KEY);
	if (stored) {
		memorySubject = stored;
		return stored;
	}
	const created = crypto.randomUUID();
	memorySubject = created;
	storageSet(SUBJECT_KEY, created);
	return created;
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
	const tokenProvider = async (): Promise<string> => {
		const response = await fetch("/session", {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({ room: code, subject: subject() }),
		});
		if (!response.ok) {
			let message = "Could not start the room";
			try {
				const body = (await response.json()) as { error?: string };
				if (body.error) message = body.error;
			} catch {}
			throw new Error(message);
		}
		const body = (await response.json()) as { token?: string };
		if (!body.token) throw new Error("The room returned no session");
		return body.token;
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
	await client.connect();
	return client;
}
