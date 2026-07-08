const doc_id = @import("typed/doc_id.zig");
const types = @import("typed/types.zig");
const codec = @import("typed/codec.zig");

pub const DocIdError = doc_id.DocIdError;
pub const DocId = doc_id.DocId;
pub const zeroDocId = doc_id.zero;
pub const docIdFromBytes = doc_id.fromBytes;
pub const docIdToBytes = doc_id.toBytes;
pub const docIdEql = doc_id.eql;
pub const docIdHexSlice = doc_id.hexSlice;
pub const generateUuidV7 = doc_id.generateUuidV7;

pub const ScalarValue = types.ScalarValue;
pub const Value = types.Value;
pub const Record = types.Record;
pub const Cursor = types.Cursor;
pub const deinitValueSlice = types.deinitValueSlice;

pub const valueFromPayload = codec.fromPayload;
pub const valueFromJson = codec.fromJson;
pub const valueFromDynamicJson = codec.fromDynamicJson;
pub const jsonAlloc = codec.jsonAlloc;
pub const validateValue = codec.validateValue;
pub const writeMsgPack = codec.writeMsgPack;
