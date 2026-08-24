const std = @import("std");

const schema_system = @import("../schema/system.zig");
const schema_types = @import("../schema/types.zig");
const sql_buf = @import("buf.zig");

const SqlBuf = sql_buf.SqlBuf;
const SqlList = sql_buf.SqlList;

/// One ZyncBase-managed index definition for a table.
/// The single source of truth shared by DDL generation and migration
/// detection/execution so their notion of "managed index" cannot drift.
pub const ManagedIndex = union(enum) {
    namespace,
    owner,
    users_identity,
    /// Index into `table.userFields()` for a field marked `indexed` or carrying `references`.
    field: usize,
    /// Index into `table.unique_constraints` (user-defined, schema order).
    unique: usize,

    pub fn isUnique(self: ManagedIndex) bool {
        return switch (self) {
            .users_identity, .unique => true,
            else => false,
        };
    }

    /// Appends the deterministic quoted index name.
    pub fn appendName(self: ManagedIndex, allocator: std.mem.Allocator, buf: *SqlBuf, table: *const schema_types.Table) !void {
        switch (self) {
            .namespace => try buf.appendIndexName(allocator, table.name, "namespace_id"),
            .owner => try buf.appendIndexName(allocator, table.name, "owner_id"),
            .users_identity => try buf.appendIndexName(allocator, table.name, "namespace_external_id"),
            .field => |fi| try buf.appendIndexName(allocator, table.name, table.userFields()[fi].name),
            .unique => |ui| try buf.appendUniqueIndexName(allocator, table.name, ui),
        }
    }

    /// Number of indexed columns in declaration order.
    pub fn columnCount(self: ManagedIndex, table: *const schema_types.Table) usize {
        return switch (self) {
            .namespace, .owner, .field => 1,
            .users_identity => 2,
            .unique => |ui| 1 + table.unique_constraints[ui].field_indexes.len,
        };
    }

    /// Copies the ordered unquoted logical column names into `out`
    /// (`out.len >= columnCount(table)`).
    pub fn columns(self: ManagedIndex, table: *const schema_types.Table, out: [][]const u8) void {
        switch (self) {
            .namespace => out[0] = "namespace_id",
            .owner => out[0] = "owner_id",
            .users_identity => {
                out[0] = "namespace_id";
                out[1] = "external_id";
            },
            .field => |fi| out[0] = table.userFields()[fi].name,
            .unique => |ui| {
                out[0] = "namespace_id";
                for (table.unique_constraints[ui].field_indexes, 0..) |field_index, i| {
                    out[i + 1] = table.userFields()[field_index].name;
                }
            },
        }
    }

    /// Appends the ordered quoted column list `(a, b, ...)`.
    pub fn appendColumnList(self: ManagedIndex, allocator: std.mem.Allocator, buf: *SqlBuf, table: *const schema_types.Table) !void {
        var list = SqlList.init(buf, ", ");
        switch (self) {
            .namespace => try list.appendItemSlice(allocator, schema_system.quoted_namespace_id),
            .owner => try list.appendItemSlice(allocator, schema_system.quoted_owner_id),
            .users_identity => {
                try list.appendItemSlice(allocator, schema_system.quoted_namespace_id);
                try list.appendItemSlice(allocator, schema_system.quoted_external_id);
            },
            .field => |fi| try list.appendItemSlice(allocator, table.userFields()[fi].name_quoted),
            .unique => |ui| {
                // namespace_id is always the first indexed column.
                try list.appendItemSlice(allocator, schema_system.quoted_namespace_id);
                for (table.unique_constraints[ui].field_indexes) |field_index| {
                    try list.appendItemSlice(allocator, table.userFields()[field_index].name_quoted);
                }
            },
        }
    }
};

/// Allocation-free iterator over every managed index of one table, in the
/// deterministic emission order: namespace, owner, users identity, ordinary
/// field/reference indexes, then user-defined unique indexes in schema order.
pub const ManagedIndexIterator = struct {
    table: *const schema_types.Table,
    pos: usize = 0,

    const header_count: usize = 3;

    pub fn init(table: *const schema_types.Table) ManagedIndexIterator {
        return .{ .table = table };
    }

    pub fn next(self: *ManagedIndexIterator) ?ManagedIndex {
        const user_fields = self.table.userFields();
        const field_end = header_count + user_fields.len;
        const total = field_end + self.table.unique_constraints.len;

        while (self.pos < total) {
            const pos = self.pos;
            self.pos += 1;
            if (pos == 0) return .namespace;
            if (pos == 1) return .owner;
            if (pos == 2) {
                if (self.table.is_users_table) return .users_identity;
                continue;
            }
            if (pos < field_end) {
                const field = user_fields[pos - header_count];
                if (field.indexed or field.references != null) return .{ .field = pos - header_count };
                continue;
            }
            return .{ .unique = pos - field_end };
        }
        return null;
    }
};

pub const DDLGenerator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DDLGenerator {
        return .{ .allocator = allocator };
    }

    /// Generate DDL for a table: CREATE TABLE IF NOT EXISTS + all managed indexes.
    /// Returns a single string with all statements separated by ";\n".
    /// Caller owns the returned slice.
    pub fn generateDDL(self: *DDLGenerator, table: schema_types.Table) ![]const u8 {
        var buf = SqlBuf.init();
        defer buf.deinit(self.allocator);

        try emitCreateTable(self.allocator, &buf, table);

        var iter = ManagedIndexIterator.init(&table);
        while (iter.next()) |managed_index| {
            try buf.appendSlice(self.allocator, ";\n");
            try emitManagedIndex(self.allocator, &buf, &table, managed_index);
        }

        try buf.append(self.allocator, ';');

        return buf.toOwnedSlice(self.allocator);
    }

    /// Generate only the managed-index statements for a table, joined like
    /// `generateDDL`. Caller owns the returned slice.
    pub fn generateIndexesDDL(self: *DDLGenerator, table: schema_types.Table) ![]const u8 {
        var buf = SqlBuf.init();
        defer buf.deinit(self.allocator);

        var first = true;
        var iter = ManagedIndexIterator.init(&table);
        while (iter.next()) |managed_index| {
            if (!first) try buf.appendSlice(self.allocator, ";\n");
            first = false;
            try emitManagedIndex(self.allocator, &buf, &table, managed_index);
        }

        try buf.append(self.allocator, ';');

        return buf.toOwnedSlice(self.allocator);
    }

    /// Generate the single statement for one managed index. Caller owns the result.
    pub fn generateIndexDDL(self: *DDLGenerator, table: schema_types.Table, managed_index: ManagedIndex) ![]const u8 {
        var buf = SqlBuf.init();
        defer buf.deinit(self.allocator);

        try emitManagedIndex(self.allocator, &buf, &table, managed_index);
        try buf.append(self.allocator, ';');

        return buf.toOwnedSlice(self.allocator);
    }
};

fn emitCreateTable(allocator: std.mem.Allocator, buf: *SqlBuf, table: schema_types.Table) !void {
    try buf.appendSlice(allocator, "CREATE TABLE IF NOT EXISTS ");
    try buf.appendSlice(allocator, table.name_quoted);
    try buf.appendSlice(allocator, " (\n");

    try emitFixedLeadingColumns(allocator, buf, table);
    try emitUserColumns(allocator, buf, table);
    try emitFixedTrailingColumns(allocator, buf);
    try emitForeignKeys(allocator, buf, table);

    try buf.appendSlice(allocator, "\n)");
}

fn emitFixedLeadingColumns(allocator: std.mem.Allocator, buf: *SqlBuf, table: schema_types.Table) !void {
    try buf.appendSlice(allocator, "  ");
    try buf.appendSlice(allocator, schema_system.quoted_id);
    try buf.appendSlice(allocator, " BLOB NOT NULL CHECK(length(");
    try buf.appendSlice(allocator, schema_system.quoted_id);
    try buf.appendSlice(allocator, ") = 16),\n");
    try buf.appendSlice(allocator, "  ");
    try buf.appendSlice(allocator, schema_system.quoted_namespace_id);
    try buf.appendSlice(allocator, " INTEGER NOT NULL,\n  ");
    try buf.appendSlice(allocator, schema_system.quoted_owner_id);
    try buf.appendSlice(allocator, " BLOB NOT NULL CHECK(length(");
    try buf.appendSlice(allocator, schema_system.quoted_owner_id);
    try buf.appendSlice(allocator, ") = 16)");
    if (table.is_users_table) {
        try buf.appendSlice(allocator, ",\n  ");
        try buf.appendSlice(allocator, schema_system.quoted_external_id);
        try buf.appendSlice(allocator, " TEXT NOT NULL");
    }
}

fn emitUserColumns(allocator: std.mem.Allocator, buf: *SqlBuf, table: schema_types.Table) !void {
    for (table.userFields()) |field| {
        try buf.appendSlice(allocator, ",\n  ");
        try buf.appendSlice(allocator, field.name_quoted);
        try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, field.storage_type.toSqlType());
        if (field.required) {
            try buf.appendSlice(allocator, " NOT NULL");
        }
        if (field.needsLengthCheck()) {
            try buf.appendSlice(allocator, " CHECK(length(");
            try buf.appendSlice(allocator, field.name_quoted);
            try buf.appendSlice(allocator, ") = 16)");
        }
    }
}

fn emitFixedTrailingColumns(allocator: std.mem.Allocator, buf: *SqlBuf) !void {
    try buf.appendSlice(allocator, ",\n  ");
    try buf.appendSlice(allocator, schema_system.quoted_created_at);
    try buf.appendSlice(allocator, " INTEGER NOT NULL");
    try buf.appendSlice(allocator, ",\n  ");
    try buf.appendSlice(allocator, schema_system.quoted_updated_at);
    try buf.appendSlice(allocator, " INTEGER NOT NULL");
    try buf.appendSlice(allocator, ",\n  PRIMARY KEY (");
    try buf.appendSlice(allocator, schema_system.quoted_id);
    try buf.append(allocator, ')');
}

fn emitForeignKeys(allocator: std.mem.Allocator, buf: *SqlBuf, table: schema_types.Table) !void {
    for (table.userFields()) |field| {
        if (field.references) |ref| {
            try buf.appendSlice(allocator, ",\n  FOREIGN KEY (");
            try buf.appendSlice(allocator, field.name_quoted);
            try buf.appendSlice(allocator, ") REFERENCES ");
            try buf.appendQuoted(allocator, ref);
            try buf.appendSlice(allocator, "(");
            try buf.appendSlice(allocator, schema_system.quoted_id);
            try buf.append(allocator, ')');
            try emitOnDelete(allocator, buf, field.on_delete orelse .restrict);
        }
    }
}

fn emitOnDelete(allocator: std.mem.Allocator, buf: *SqlBuf, od: schema_types.OnDelete) !void {
    const fragment: []const u8 = switch (od) {
        .cascade => " ON DELETE CASCADE",
        .restrict => " ON DELETE RESTRICT",
        .set_null => " ON DELETE SET NULL",
    };
    try buf.appendSlice(allocator, fragment);
}

/// Emit one managed-index statement: `CREATE [UNIQUE] INDEX IF NOT EXISTS ...`
fn emitManagedIndex(allocator: std.mem.Allocator, buf: *SqlBuf, table: *const schema_types.Table, managed_index: ManagedIndex) !void {
    if (managed_index.isUnique()) {
        try buf.appendSlice(allocator, "CREATE UNIQUE INDEX IF NOT EXISTS ");
    } else {
        try buf.appendSlice(allocator, "CREATE INDEX IF NOT EXISTS ");
    }
    try managed_index.appendName(allocator, buf, table);
    try buf.appendSlice(allocator, " ON ");
    try buf.appendSlice(allocator, table.name_quoted);
    try buf.append(allocator, '(');
    try managed_index.appendColumnList(allocator, buf, table);
    try buf.append(allocator, ')');
}
