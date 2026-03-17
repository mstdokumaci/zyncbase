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
        console.log(`Received ${data.length} bytes from server`);
        const message = decode(data) as ZyncBaseMessage;
        console.log("Received message:", JSON.stringify(message));
        
        if (message.id && this.pendingRequests.has(message.id)) {
          const { resolve, reject } = this.pendingRequests.get(message.id)!;
          this.pendingRequests.delete(message.id);
          
          if (message.type === "ok") {
            resolve(message.value ?? null);
          } else {
            reject(message);
          }
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
    return this.sendRequest({
        type: "StoreSet",
        id,
        namespace,
        path,
        value
    });
  }

  async get(namespace: string, path: string[]): Promise<any> {
    const id = this.nextId++;
    return this.sendRequest({
        type: "StoreGet",
        id,
        namespace,
        path,
    });
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
        // Ignore errors during polling (e.g. NOT_FOUND)
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
