import { decodeMulti, encode } from "./msgpack.ts";

export const WireMessageType = {
	ok: 0x00,
	error: 0x01,
	Connected: 0x02,
	SchemaSync: 0x03,
	StoreSetNamespace: 0x10,
	StoreSet: 0x11,
	StoreSubscribe: 0x15,
	StoreUnsubscribe: 0x16,
	StoreDelta: 0x18,
	WriteCommitted: 0x19,
	WriteError: 0x1a,
	PresenceSetNamespace: 0x20,
	PresenceSet: 0x21,
	PresenceSetShared: 0x22,
	PresenceSubscribe: 0x23,
	PresenceUnsubscribe: 0x24,
	PresenceSubscribeShared: 0x25,
	PresenceUnsubscribeShared: 0x26,
	PresenceBroadcast: 0x28,
	SharedStateBroadcast: 0x29,
} as const;

export type WireMessage = Record<string, unknown> & { type: number };

export interface SchemaSyncMessage extends WireMessage {
	type: typeof WireMessageType.SchemaSync;
	tables: string[];
	fields: string[][];
	presenceUserFields?: string[];
	presenceSharedFields?: string[];
}

export class WireSchema {
	readonly tables: string[];
	readonly fields: string[][];
	readonly presenceUserFields: string[];
	readonly presenceSharedFields: string[];

	constructor(message: SchemaSyncMessage) {
		this.tables = message.tables;
		this.fields = message.fields;
		this.presenceUserFields = message.presenceUserFields ?? [];
		this.presenceSharedFields = message.presenceSharedFields ?? [];
	}

	table(name: string): number {
		const index = this.tables.indexOf(name);
		if (index < 0) throw new Error(`SchemaSync missing table ${name}`);
		return index;
	}

	field(tableIndex: number, name: string): number {
		const index = this.fields[tableIndex]?.indexOf(name) ?? -1;
		if (index < 0) {
			throw new Error(`SchemaSync missing field ${name} in table ${tableIndex}`);
		}
		return index;
	}

	presenceUserField(name: string): number {
		return requiredIndex(this.presenceUserFields, name, "presence user field");
	}

	presenceSharedField(name: string): number {
		return requiredIndex(this.presenceSharedFields, name, "presence shared field");
	}
}

function requiredIndex(values: string[], name: string, kind: string): number {
	const index = values.indexOf(name);
	if (index < 0) throw new Error(`SchemaSync missing ${kind} ${name}`);
	return index;
}

export function encodeMessage(message: WireMessage): Uint8Array {
	return encode(message) as Uint8Array;
}

export function decodeMessages(
	data: ArrayBuffer | ArrayBufferView,
): WireMessage[] {
	const bytes = ArrayBuffer.isView(data)
		? new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
		: new Uint8Array(data);
	const messages: WireMessage[] = [];
	for (const decoded of decodeMulti(bytes)) {
		if (
			decoded === null ||
			typeof decoded !== "object" ||
			!("type" in decoded) ||
			typeof decoded.type !== "number"
		) {
			throw new Error("Invalid MessagePack wire message");
		}
		messages.push(decoded as WireMessage);
	}
	return messages;
}

export function pairValue(
	pairs: unknown,
	fieldIndex: number,
): unknown | undefined {
	if (!Array.isArray(pairs)) return undefined;
	for (const pair of pairs) {
		if (Array.isArray(pair) && pair[0] === fieldIndex) return pair[1];
	}
	return undefined;
}

export function documentId(writer: number): Uint8Array {
	const bytes = new Uint8Array(16);
	const view = new DataView(bytes.buffer);
	view.setUint32(0, 0x7a796e63);
	view.setUint32(4, 0x62617365);
	view.setUint32(8, Math.floor(writer / 0x1_0000_0000));
	view.setUint32(12, writer >>> 0);
	return bytes;
}

export function concatBytes(...parts: Uint8Array[]): Uint8Array {
	const result = new Uint8Array(
		parts.reduce((total, part) => total + part.byteLength, 0),
	);
	let offset = 0;
	for (const part of parts) {
		result.set(part, offset);
		offset += part.byteLength;
	}
	return result;
}
