const std = @import("std");
const schema_types = @import("../schema/types.zig");
const schema_system = @import("../schema/system.zig");
const SqlBuf = @import("buf.zig").SqlBuf;

pub const DDLGenerator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DDLGenerator {
        return .{ .allocator = allocator };
    }

    /// Generate DDL for a table: CREATE TABLE IF NOT EXISTS + CREATE INDEX statements.
    /// Returns a single string with all statements separated by ";\n".
    /// Caller owns the returned slice.
    pub fn generateDDL(self: *DDLGenerator, table: schema_types.Table) ![]const u8 {
        var buf = SqlBuf.init();
        defer buf.deinit(self.allocator);

        try emitCreateTable(self.allocator, &buf, table);
        try emitNamespaceIndex(self.allocator, &buf, table);
        try emitOwnerIndex(self.allocator, &buf, table);
        try emitUsersUniqueIndex(self.allocator, &buf, table);
        try emitFieldIndexes(self.allocator, &buf, table);

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
            if (field.on_delete) |od| {
                try emitOnDelete(allocator, buf, od);
            }
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

fn emitNamespaceIndex(allocator: std.mem.Allocator, buf: *SqlBuf, table: schema_types.Table) !void {
    try buf.appendSlice(allocator, ";\nCREATE INDEX IF NOT EXISTS ");
    try buf.appendIndexName(allocator, table.name, "namespace_id");
    try buf.appendSlice(allocator, " ON ");
    try buf.appendSlice(allocator, table.name_quoted);
    try buf.appendSlice(allocator, "(");
    try buf.appendSlice(allocator, schema_system.quoted_namespace_id);
    try buf.append(allocator, ')');
}

fn emitOwnerIndex(allocator: std.mem.Allocator, buf: *SqlBuf, table: schema_types.Table) !void {
    try buf.appendSlice(allocator, ";\nCREATE INDEX IF NOT EXISTS ");
    try buf.appendIndexName(allocator, table.name, "owner_id");
    try buf.appendSlice(allocator, " ON ");
    try buf.appendSlice(allocator, table.name_quoted);
    try buf.appendSlice(allocator, "(");
    try buf.appendSlice(allocator, schema_system.quoted_owner_id);
    try buf.append(allocator, ')');
}

fn emitUsersUniqueIndex(allocator: std.mem.Allocator, buf: *SqlBuf, table: schema_types.Table) !void {
    if (!table.is_users_table) return;
    try buf.appendSlice(allocator, ";\nCREATE UNIQUE INDEX IF NOT EXISTS ");
    try buf.appendIndexName(allocator, table.name, "namespace_external_id");
    try buf.appendSlice(allocator, " ON ");
    try buf.appendSlice(allocator, table.name_quoted);
    try buf.appendSlice(allocator, "(");
    try buf.appendSlice(allocator, schema_system.quoted_namespace_id);
    try buf.appendSlice(allocator, ", ");
    try buf.appendSlice(allocator, schema_system.quoted_external_id);
    try buf.append(allocator, ')');
}

fn emitFieldIndexes(allocator: std.mem.Allocator, buf: *SqlBuf, table: schema_types.Table) !void {
    for (table.userFields()) |field| {
        if (field.indexed) {
            try buf.appendSlice(allocator, ";\nCREATE INDEX IF NOT EXISTS ");
            try buf.appendIndexName(allocator, table.name, field.name);
            try buf.appendSlice(allocator, " ON ");
            try buf.appendSlice(allocator, table.name_quoted);
            try buf.append(allocator, '(');
            try buf.appendSlice(allocator, field.name_quoted);
            try buf.append(allocator, ')');
        }
    }
}
