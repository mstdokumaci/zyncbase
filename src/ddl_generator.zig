const std = @import("std");
const schema_manager = @import("schema_manager.zig");
const sql_identifier = @import("sql_identifier.zig");

pub const DDLGenerator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DDLGenerator {
        return .{ .allocator = allocator };
    }

    /// Generate DDL for a table: CREATE TABLE IF NOT EXISTS + CREATE INDEX statements.
    /// Returns a single string with all statements separated by ";\n".
    /// Caller owns the returned slice.
    pub fn generateDDL(self: *DDLGenerator, table: schema_manager.Table) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);

        // ── CREATE TABLE ──────────────────────────────────────────────────────
        try buf.appendSlice(self.allocator, "CREATE TABLE IF NOT EXISTS ");
        try sql_identifier.appendQuoted(self.allocator, &buf, table.name);
        try buf.appendSlice(self.allocator, " (\n");

        // Fixed leading columns
        try buf.appendSlice(self.allocator, "  ");
        try sql_identifier.appendQuoted(self.allocator, &buf, "id");
        try buf.appendSlice(self.allocator, " BLOB NOT NULL CHECK(length(");
        try sql_identifier.appendQuoted(self.allocator, &buf, "id");
        try buf.appendSlice(self.allocator, ") = 16),\n");
        try buf.appendSlice(self.allocator, "  ");
        try sql_identifier.appendQuoted(self.allocator, &buf, "namespace_id");
        try buf.appendSlice(self.allocator, " TEXT NOT NULL");
        // One column per field
        for (table.fields) |field| {
            try buf.appendSlice(self.allocator, ",\n  ");
            try sql_identifier.appendQuoted(self.allocator, &buf, field.name);
            try buf.append(self.allocator, ' ');
            try buf.appendSlice(self.allocator, field.sql_type.toSqlType());
            if (field.required) {
                try buf.appendSlice(self.allocator, " NOT NULL");
            }
            if (field.sql_type == .doc_id) {
                try buf.appendSlice(self.allocator, " CHECK(length(");
                try sql_identifier.appendQuoted(self.allocator, &buf, field.name);
                try buf.appendSlice(self.allocator, ") = 16)");
            }
        }

        // Fixed trailing columns
        try buf.appendSlice(self.allocator, ",\n  ");
        try sql_identifier.appendQuoted(self.allocator, &buf, "created_at");
        try buf.appendSlice(self.allocator, " INTEGER NOT NULL");
        try buf.appendSlice(self.allocator, ",\n  ");
        try sql_identifier.appendQuoted(self.allocator, &buf, "updated_at");
        try buf.appendSlice(self.allocator, " INTEGER NOT NULL");

        // Global document identity is keyed by id; namespace remains a scoped column.
        try buf.appendSlice(self.allocator, ",\n  PRIMARY KEY (");
        try sql_identifier.appendQuoted(self.allocator, &buf, "id");
        try buf.append(self.allocator, ')');

        // FOREIGN KEY constraints
        for (table.fields) |field| {
            if (field.references) |ref| {
                try buf.appendSlice(self.allocator, ",\n  FOREIGN KEY (");
                try sql_identifier.appendQuoted(self.allocator, &buf, field.name);
                try buf.appendSlice(self.allocator, ") REFERENCES ");
                try sql_identifier.appendQuoted(self.allocator, &buf, ref);
                try buf.appendSlice(self.allocator, "(");
                try sql_identifier.appendQuoted(self.allocator, &buf, "id");
                try buf.append(self.allocator, ')');
                if (field.on_delete) |od| {
                    switch (od) {
                        .cascade => try buf.appendSlice(self.allocator, " ON DELETE CASCADE"),
                        .restrict => try buf.appendSlice(self.allocator, " ON DELETE RESTRICT"),
                        .set_null => try buf.appendSlice(self.allocator, " ON DELETE SET NULL"),
                    }
                }
            }
        }

        try buf.appendSlice(self.allocator, "\n)");

        // ── CREATE INDEX on namespace_id ──────────────────────────────────────
        try buf.appendSlice(self.allocator, ";\nCREATE INDEX IF NOT EXISTS ");
        try appendQuotedIndexName(self.allocator, &buf, table.name, "namespace_id");
        try buf.appendSlice(self.allocator, " ON ");
        try sql_identifier.appendQuoted(self.allocator, &buf, table.name);
        try buf.appendSlice(self.allocator, "(");
        try sql_identifier.appendQuoted(self.allocator, &buf, "namespace_id");
        try buf.append(self.allocator, ')');

        // ── CREATE INDEX for each indexed field ───────────────────────────────
        for (table.fields) |field| {
            if (field.indexed) {
                try buf.appendSlice(self.allocator, ";\nCREATE INDEX IF NOT EXISTS ");
                try appendQuotedIndexName(self.allocator, &buf, table.name, field.name);
                try buf.appendSlice(self.allocator, " ON ");
                try sql_identifier.appendQuoted(self.allocator, &buf, table.name);
                try buf.append(self.allocator, '(');
                try sql_identifier.appendQuoted(self.allocator, &buf, field.name);
                try buf.append(self.allocator, ')');
            }
        }

        try buf.append(self.allocator, ';');

        return buf.toOwnedSlice(self.allocator);
    }
};

fn appendQuotedIndexName(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    table_name: []const u8,
    field_name: []const u8,
) !void {
    try buf.append(allocator, '"');
    try buf.appendSlice(allocator, "idx_");
    try buf.appendSlice(allocator, table_name);
    try buf.append(allocator, '_');
    try buf.appendSlice(allocator, field_name);
    try buf.append(allocator, '"');
}
