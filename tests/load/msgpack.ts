const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

class Writer {
	private bytes = new Uint8Array(256);
	private view = new DataView(this.bytes.buffer);
	private offset = 0;

	finish(): Uint8Array {
		return this.bytes.slice(0, this.offset);
	}

	value(value: unknown): void {
		if (value === null) return this.u8(0xc0);
		if (value === false) return this.u8(0xc2);
		if (value === true) return this.u8(0xc3);
		if (typeof value === "number") return this.number(value);
		if (typeof value === "string") return this.string(value);
		if (value instanceof Uint8Array) return this.binary(value);
		if (Array.isArray(value)) return this.array(value);
		if (typeof value === "object") return this.map(value as Record<string, unknown>);
		throw new Error(`Unsupported MessagePack value: ${typeof value}`);
	}

	private number(value: number): void {
		if (!Number.isFinite(value) || !Number.isInteger(value)) return this.f64(value);
		if (!Number.isSafeInteger(value)) throw new Error("Unsafe MessagePack integer");
		if (value >= 0) {
			if (value <= 0x7f) return this.u8(value);
			if (value <= 0xff) return this.u8(0xcc, value);
			if (value <= 0xffff) return this.u16(0xcd, value);
			if (value <= 0xffff_ffff) return this.u32(0xce, value);
			this.ensure(9);
			this.view.setUint8(this.offset, 0xcf);
			this.view.setUint32(this.offset + 1, Math.floor(value / 0x1_0000_0000));
			this.view.setUint32(this.offset + 5, value >>> 0);
			this.offset += 9;
			return;
		}
		if (value >= -32) return this.u8(value & 0xff);
		if (value >= -0x80) {
			this.ensure(2);
			this.view.setUint8(this.offset, 0xd0);
			this.view.setInt8(this.offset + 1, value);
			this.offset += 2;
			return;
		}
		if (value >= -0x8000) {
			this.ensure(3);
			this.view.setUint8(this.offset, 0xd1);
			this.view.setInt16(this.offset + 1, value);
			this.offset += 3;
			return;
		}
		if (value >= -0x8000_0000) {
			this.ensure(5);
			this.view.setUint8(this.offset, 0xd2);
			this.view.setInt32(this.offset + 1, value);
			this.offset += 5;
			return;
		}
		const high = Math.floor(value / 0x1_0000_0000);
		const low = value - high * 0x1_0000_0000;
		this.ensure(9);
		this.view.setUint8(this.offset, 0xd3);
		this.view.setInt32(this.offset + 1, high);
		this.view.setUint32(this.offset + 5, low);
		this.offset += 9;
	}

	private f64(value: number): void {
		this.ensure(9);
		this.view.setUint8(this.offset, 0xcb);
		this.view.setFloat64(this.offset + 1, value);
		this.offset += 9;
	}

	private string(value: string): void {
		const encoded = textEncoder.encode(value);
		if (encoded.length < 32) this.u8(0xa0 | encoded.length);
		else if (encoded.length <= 0xff) this.u8(0xd9, encoded.length);
		else if (encoded.length <= 0xffff) this.u16(0xda, encoded.length);
		else this.u32(0xdb, encoded.length);
		this.raw(encoded);
	}

	private binary(value: Uint8Array): void {
		if (value.length <= 0xff) this.u8(0xc4, value.length);
		else if (value.length <= 0xffff) this.u16(0xc5, value.length);
		else this.u32(0xc6, value.length);
		this.raw(value);
	}

	private array(value: unknown[]): void {
		if (value.length < 16) this.u8(0x90 | value.length);
		else if (value.length <= 0xffff) this.u16(0xdc, value.length);
		else this.u32(0xdd, value.length);
		for (const item of value) this.value(item);
	}

	private map(value: Record<string, unknown>): void {
		const entries = Object.entries(value);
		if (entries.length < 16) this.u8(0x80 | entries.length);
		else if (entries.length <= 0xffff) this.u16(0xde, entries.length);
		else this.u32(0xdf, entries.length);
		for (const [key, item] of entries) {
			this.string(key);
			this.value(item);
		}
	}

	private u8(...values: number[]): void {
		this.ensure(values.length);
		for (const value of values) this.view.setUint8(this.offset++, value);
	}

	private u16(type: number, value: number): void {
		this.ensure(3);
		this.view.setUint8(this.offset, type);
		this.view.setUint16(this.offset + 1, value);
		this.offset += 3;
	}

	private u32(type: number, value: number): void {
		this.ensure(5);
		this.view.setUint8(this.offset, type);
		this.view.setUint32(this.offset + 1, value);
		this.offset += 5;
	}

	private raw(value: Uint8Array): void {
		this.ensure(value.length);
		this.bytes.set(value, this.offset);
		this.offset += value.length;
	}

	private ensure(length: number): void {
		if (this.offset + length <= this.bytes.length) return;
		let capacity = this.bytes.length;
		while (capacity < this.offset + length) capacity *= 2;
		const grown = new Uint8Array(capacity);
		grown.set(this.bytes);
		this.bytes = grown;
		this.view = new DataView(grown.buffer);
	}
}

class Reader {
	private readonly view: DataView;
	private offset = 0;

	constructor(private readonly bytes: Uint8Array) {
		this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
	}

	done(): boolean {
		return this.offset === this.bytes.length;
	}

	value(): unknown {
		const type = this.readU8();
		if (type <= 0x7f) return type;
		if (type >= 0xe0) return type - 0x100;
		if ((type & 0xf0) === 0x80) return this.map(type & 0x0f);
		if ((type & 0xf0) === 0x90) return this.array(type & 0x0f);
		if ((type & 0xe0) === 0xa0) return this.string(type & 0x1f);
		switch (type) {
			case 0xc0: return null;
			case 0xc2: return false;
			case 0xc3: return true;
			case 0xc4: return this.binary(this.readU8());
			case 0xc5: return this.binary(this.readU16());
			case 0xc6: return this.binary(this.readU32());
			case 0xca: return this.f32();
			case 0xcb: return this.f64();
			case 0xcc: return this.readU8();
			case 0xcd: return this.readU16();
			case 0xce: return this.readU32();
			case 0xcf: return this.readU64();
			case 0xd0: return this.i8();
			case 0xd1: return this.i16();
			case 0xd2: return this.i32();
			case 0xd3: return this.i64();
			case 0xd9: return this.string(this.readU8());
			case 0xda: return this.string(this.readU16());
			case 0xdb: return this.string(this.readU32());
			case 0xdc: return this.array(this.readU16());
			case 0xdd: return this.array(this.readU32());
			case 0xde: return this.map(this.readU16());
			case 0xdf: return this.map(this.readU32());
			default: throw new Error(`Unsupported MessagePack type 0x${type.toString(16)}`);
		}
	}

	private array(length: number): unknown[] {
		const value = new Array<unknown>(length);
		for (let index = 0; index < length; index++) value[index] = this.value();
		return value;
	}

	private map(length: number): Record<string, unknown> {
		const value: Record<string, unknown> = {};
		for (let index = 0; index < length; index++) {
			const key = this.value();
			if (typeof key !== "string") throw new Error("MessagePack map key is not a string");
			value[key] = this.value();
		}
		return value;
	}

	private string(length: number): string {
		const end = this.offset + length;
		if (end > this.bytes.length) throw new Error("Truncated MessagePack string");
		const value = textDecoder.decode(this.bytes.subarray(this.offset, end));
		this.offset = end;
		return value;
	}

	private binary(length: number): Uint8Array {
		const end = this.offset + length;
		if (end > this.bytes.length) throw new Error("Truncated MessagePack binary");
		const value = this.bytes.slice(this.offset, end);
		this.offset = end;
		return value;
	}

	private readU8(): number {
		if (this.offset >= this.bytes.length) throw new Error("Truncated MessagePack value");
		return this.view.getUint8(this.offset++);
	}

	private readU16(): number {
		const value = this.view.getUint16(this.offset);
		this.offset += 2;
		return value;
	}

	private readU32(): number {
		const value = this.view.getUint32(this.offset);
		this.offset += 4;
		return value;
	}

	private readU64(): number {
		const value = this.view.getUint32(this.offset) * 0x1_0000_0000 + this.view.getUint32(this.offset + 4);
		this.offset += 8;
		if (!Number.isSafeInteger(value)) throw new Error("Unsafe MessagePack integer");
		return value;
	}

	private i8(): number { const value = this.view.getInt8(this.offset); this.offset++; return value; }
	private i16(): number { const value = this.view.getInt16(this.offset); this.offset += 2; return value; }
	private i32(): number { const value = this.view.getInt32(this.offset); this.offset += 4; return value; }
	private i64(): number { const high = this.view.getInt32(this.offset); const low = this.view.getUint32(this.offset + 4); this.offset += 8; return high * 0x1_0000_0000 + low; }
	private f32(): number { const value = this.view.getFloat32(this.offset); this.offset += 4; return value; }
	private f64(): number { const value = this.view.getFloat64(this.offset); this.offset += 8; return value; }
}

export function encode(value: unknown): Uint8Array {
	const writer = new Writer();
	writer.value(value);
	return writer.finish();
}

export function decodeMulti(bytes: Uint8Array): unknown[] {
	const reader = new Reader(bytes);
	const values: unknown[] = [];
	while (!reader.done()) values.push(reader.value());
	return values;
}
