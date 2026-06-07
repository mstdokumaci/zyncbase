const ANON_SUBJECT_STORAGE_KEY = "zyncbase_anon_subject";
const ANON_SUBJECT_PREFIX = "anon:";

let inMemorySubject: string | null = null;

function generateHexBytes(byteCount: number): string {
	const bytes = new Uint8Array(byteCount);
	crypto.getRandomValues(bytes);
	let hex = "";
	for (let i = 0; i < bytes.length; i++) {
		hex += bytes[i].toString(16).padStart(2, "0");
	}
	return hex;
}

function generateAnonymousSubject(): string {
	return `${ANON_SUBJECT_PREFIX}${generateHexBytes(32)}`;
}

function readFromStorage(): string | null {
	if (typeof localStorage !== "undefined") {
		try {
			return localStorage.getItem(ANON_SUBJECT_STORAGE_KEY);
		} catch {
			return null;
		}
	}
	return null;
}

function writeToStorage(subject: string): void {
	if (typeof localStorage !== "undefined") {
		try {
			localStorage.setItem(ANON_SUBJECT_STORAGE_KEY, subject);
		} catch {}
	}
}

export function getOrCreateAnonymousSubject(): string {
	if (inMemorySubject) return inMemorySubject;

	const stored = readFromStorage();
	if (stored) {
		inMemorySubject = stored;
		return stored;
	}

	const subject = generateAnonymousSubject();
	inMemorySubject = subject;
	writeToStorage(subject);
	return subject;
}

export function resetAnonymousSubject(): void {
	inMemorySubject = null;
	if (typeof localStorage !== "undefined") {
		try {
			localStorage.removeItem(ANON_SUBJECT_STORAGE_KEY);
		} catch {}
	}
}

export function resetInMemorySubject(): void {
	inMemorySubject = null;
}
