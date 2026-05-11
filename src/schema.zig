const types = @import("schema/types.zig");
const system = @import("schema/system.zig");
const parse = @import("schema/parse.zig");
const index_mod = @import("schema/index.zig");
const errors = @import("schema/errors.zig");

pub const Schema = types.Schema;
pub const Table = types.Table;
pub const Field = types.Field;
pub const FieldType = types.FieldType;
pub const StorageType = types.StorageType;
pub const FieldKind = types.FieldKind;
pub const OnDelete = types.OnDelete;
pub const Metadata = types.Metadata;

pub const SchemaError = errors.SchemaError;

pub const global_namespace_id = system.global_namespace_id;
pub const global_namespace_name = system.global_namespace_name;
pub const implicit_users_schema_json = system.implicit_users_schema_json;

pub const quoted_id = system.quoted_id;
pub const quoted_namespace_id = system.quoted_namespace_id;
pub const quoted_owner_id = system.quoted_owner_id;
pub const quoted_external_id = system.quoted_external_id;
pub const quoted_created_at = system.quoted_created_at;
pub const quoted_updated_at = system.quoted_updated_at;

pub const id_field_index = system.id_field_index;
pub const namespace_id_field_index = system.namespace_id_field_index;
pub const owner_id_field_index = system.owner_id_field_index;
pub const first_user_field_index = system.first_user_field_index;
pub const leading_system_field_count = system.leading_system_field_count;
pub const trailing_system_field_count = system.trailing_system_field_count;

pub const getSystemColumn = system.getSystemColumn;
pub const isSystemColumn = system.isSystemColumn;
pub const effectiveNamespaceLabel = system.effectiveNamespaceLabel;

pub const mapType = parse.mapType;
pub const mapPrimitiveType = parse.mapPrimitiveType;
pub const parseOnDelete = parse.parseOnDelete;
pub const buildRuntimeTable = parse.buildRuntimeTable;
pub const buildTableIndex = index_mod.buildTableIndex;
