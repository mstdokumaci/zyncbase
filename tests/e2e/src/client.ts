import { encode, decode } from "@msgpack/msgpack";

export interface ZyncBaseMessage {
  type: string;
  id?: number;
  [key: string]: any;
}

export class ZyncBaseClient {
  private ws: WebSocket;
  private nextId = 1;
  private pendingRequests = new Map<number, { resolve: (val: any) => void; reject: (err: any) => void }>();
  private connectedPromise: Promise<void>;

  constructor(private url: string = "ws://127.0.0.1:3000") {
    this.ws = new WebSocket(url);
    this.ws.binaryType = "arraybuffer";
    
    this.connectedPromise = new Promise((resolve, reject) => {
      this.ws.onopen = () => resolve();
      this.ws.onerror = (err) => reject(err);
    });

    this.ws.onmessage = (event) => {
      try {
        const data = new Uint8Array(event.data as ArrayBuffer);
        const message = decode(data) as ZyncBaseMessage;
        
        if (message.id && this.pendingRequests.has(message.id)) {
          const { resolve, reject } = this.pendingRequests.get(message.id)!;
          this.pendingRequests.delete(message.id);
          
          if (message.type === "StoreErrorResponse" || message.type === "error") {
            reject(message);
          } else {
            // Handle all successful responses (StoreQueryResponse, StoreSuccessResponse, etc.)
            resolve(message.value ?? null);
          }
        } else if (message.type === "StoreDelta") {
          // Push notifications (real-time updates) will be handled separately if needed
        }
      } catch (err) {
        console.error("Error decoding message:", err, "Raw data:", event.data);
      }
    };
  }

  async connect() {
    return this.connectedPromise;
  }

  async set(namespace: string, path: string[], value: any): Promise<void> {
    const id = this.nextId++;
    
    // If setting a whole object at once (segments.len == 2), flatten it
    let flattenedValue = value;
    if (path.length === 2 && value !== null && typeof value === 'object' && !Array.isArray(value)) {
      flattenedValue = this.flatten(value);
    }

    return this.sendRequest({
        type: "StoreSet",
        id,
        namespace,
        path,
        value: flattenedValue
    });
  }

  async get(namespace: string, path: string[]): Promise<any> {
    if (path.length === 0) throw new Error("Path must not be empty");
    const collection = path[0];
    
    // Path: [table, id, field1, field2...]
    // Query by ID for anything deeper than just collection
    let conditions: any[] | undefined = undefined;
    if (path.length >= 2) {
      conditions = [["id", 0, path[1]]]; // op 0 = eq
    }

    const results = await this.query(namespace, collection, { conditions });
    
    // If just collection read, return the whole array
    if (path.length === 1) return results;

    // Specific record read
    if (!results || results.length === 0) return null;

    const record = results[0];
    if (path.length === 2) return record;

    // Extract nested field (path[2...])
    let current = record;
    for (let i = 2; i < path.length; i++) {
      if (current === null || typeof current !== 'object' || !(path[i] in current)) {
        throw { code: "FIELD_NOT_FOUND", message: `Field ${path[i]} not found` };
      }
      current = current[path[i]];
    }
    return current;
  }

  async query(namespace: string, collection: string, filter: { conditions?: any[], orderBy?: any[], limit?: number, after?: any } = {}): Promise<any[]> {
    const id = this.nextId++;
    const message: ZyncBaseMessage = {
      type: "StoreQuery",
      id,
      namespace,
      collection,
      ...filter
    };

    const response = await this.sendRequest(message);
    const results = (response as any[]) || [];
    return results.map((r: any) => this.unflatten(r));
  }

  /**
   * Local flattening: { a: { b: 1 } } -> { "a__b": 1 }
   */
  private flatten(obj: any, prefix = ""): Record<string, any> {
    let result: Record<string, any> = {};
    for (const key in obj) {
      const name = prefix ? `${prefix}__${key}` : key;
      if (obj[key] !== null && typeof obj[key] === 'object' && !Array.isArray(obj[key])) {
        Object.assign(result, this.flatten(obj[key], name));
      } else {
        result[name] = obj[key];
      }
    }
    return result;
  }

  /**
   * Local unflattening: { "a__b": 1 } -> { a: { b: 1 } }
   */
  private unflatten(obj: Record<string, any>): any {
    const result: any = {};
    for (const key in obj) {
      const parts = key.split("__");
      let current = result;
      for (let i = 0; i < parts.length; i++) {
        const part = parts[i];
        if (i === parts.length - 1) {
          current[part] = obj[key];
        } else {
          current[part] = current[part] || {};
          current = current[part];
        }
      }
    }
    return result;
  }

  /**
   * Periodically polls the server until the predicate is satisfied or timeout is reached.
   */
  async waitFor<T>(
    namespace: string,
    path: string[],
    predicate: (val: any) => T | null | undefined,
    timeoutMs: number = 2000,
    intervalMs: number = 100
  ): Promise<T> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      try {
        const val = await this.get(namespace, path);
        const result = predicate(val);
        if (result !== null && result !== undefined) return result as T;
      } catch (err) {
        // Ignore errors during polling
      }
      await new Promise(resolve => setTimeout(resolve, intervalMs));
    }
    throw new Error(`Timeout waiting for condition on path: ${path.join("/")}`);
  }

  private async sendRequest(msg: ZyncBaseMessage): Promise<any> {
    await this.connect();
    return new Promise((resolve, reject) => {
      this.pendingRequests.set(msg.id!, { resolve, reject });
      const encoded = encode(msg);
      this.ws.send(encoded);
    });
  }

  close() {
    this.ws.close();
  }
}
