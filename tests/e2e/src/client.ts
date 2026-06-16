import type {
	BatchOperation,
	JsonValue,
	Presence,
	ZyncBaseClient as SDKClient,
	Store,
} from "@zyncbase/client";
import { createClient } from "@zyncbase/client";

/**
 * Thin adapter wrapping the @zyncbase/client SDK.
 * Exposes the same surface used by the E2E test files:
 *   connect(), set(ns, path, value), get(ns, path), close()
 *
 * The `ns` (namespace) parameter is accepted for API compatibility but ignored —
 * the new SDK does not use namespaces.
 *
 * `store` is exposed directly so tests can use `store.listen` for real-time updates.
 * `presence` is exposed directly so tests can use the presence API.
 */
export class ZyncBaseClient {
	private client: SDKClient;
	/** Underlying SDK store — use for `store.listen`, `store.get`, etc. */
	readonly store: Store;
	/** Underlying SDK presence — use for `presence.set`, `presence.subscribe`, etc. */
	readonly presence: Presence;

	constructor(
		urlOrOptions:
			| string
			| { url: string; debug?: boolean } = "ws://127.0.0.1:3000",
	) {
		const options =
			typeof urlOrOptions === "string" ? { url: urlOrOptions } : urlOrOptions;
		this.client = createClient({ ...options, auth: { anonymous: true } });
		this.store = this.client.store;
		this.presence = this.client.presence;
	}

	connect(): Promise<void> {
		return this.client.connect();
	}

	async setNamespace(ns: string): Promise<void> {
		await this.client.setStoreNamespace(ns);
	}

	async setPresenceNamespace(ns: string): Promise<void> {
		await this.client.setPresenceNamespace(ns);
	}

	async batch(operations: BatchOperation[]): Promise<void> {
		return await this.client.store.batch(operations);
	}

	/**
	 * Set a value at the given path.
	 * Now natively awaits the server's acknowledgement.
	 */
	async set(ns: string, path: string[], value: JsonValue): Promise<void> {
		await this.client.setStoreNamespace(ns);
		return await this.client.store.set(path, value);
	}

	/**
	 * Get the value at the given path.
	 */
	async get(ns: string, path: string[]): Promise<JsonValue | null | undefined> {
		await this.client.setStoreNamespace(ns);
		return await this.client.store.get(path);
	}

	close(): void {
		this.client.disconnect();
	}
}
