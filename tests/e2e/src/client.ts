import { createClient, ZyncBaseError } from "@zyncbase/client";
import type { ZyncBaseClient as SDKClient, Store } from "@zyncbase/client";

/**
 * Thin adapter wrapping the @zyncbase/client SDK.
 * Exposes the same surface used by the E2E test files:
 *   connect(), set(ns, path, value), get(ns, path), close()
 *
 * The `ns` (namespace) parameter is accepted for API compatibility but ignored —
 * the new SDK does not use namespaces.
 *
 * `store` is exposed directly so tests can use `store.listen` for real-time updates.
 */
export class ZyncBaseClient {
  private client: SDKClient;
  /** Underlying SDK store — use for `store.listen`, `store.get`, etc. */
  readonly store: Store;

  constructor(url: string = "ws://127.0.0.1:3000") {
    this.client = createClient({ url });
    this.store = this.client.store;
  }

  connect(): Promise<void> {
    return this.client.connect();
  }

  /**
   * Set a value at the given path.
   * Now natively awaits the server's acknowledgement.
   */
  async set(ns: string, path: string[], value: any): Promise<void> {
    await this.client.setStoreNamespace(ns);
    return await this.client.store.set(path, value);
  }

  /**
   * Get the value at the given path.
   */
  async get(ns: string, path: string[]): Promise<any> {
    await this.client.setStoreNamespace(ns);
    return await this.client.store.get(path);
  }

  close(): void {
    this.client.disconnect();
  }
}
