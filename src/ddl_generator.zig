const std = @import("std");
const schema_parser = @import("schema_parser.zig");

pub const DDLGenerator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DDLGenerator {
        return .{ .allocator = allocator };
    }

    /// Generate DDL for a table: CREATE TABLE IF NOT EXISTS + CREATE INDEX statements.
    /// Returns a single string with all statements separated by ";\n".
    /// Caller owns the returned slice.
    pub fn generateDDL(self: *DDLGenerator, table: schema_parser.Table) ![]const u8 {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(self.allocator);

        // ── CREATE TABLE ──────────────────────────────────────────────────────
        try buf.appendSlice(self.allocator, "CREATE TABLE IF NOT EXISTS ");
        try buf.appendSlice(self.allocator, table.name);
        try buf.appendSlice(self.allocator, " (\n");

        // Fixed leading columns
        try buf.appendSlice(self.allocator, "  id TEXT,\n");
        try buf.appendSlice(self.allocator, "  namespace_id TEXT NOT NULL");
        // One column per field
        for (table.fields) |field| {
            try buf.appendSlice(self.allocator, ",\n  ");
            try buf.appendSlice(self.allocator, field.name);
            try buf.append(self.allocator, ' ');
            try buf.appendSlice(self.allocator, field.sql_type.toSqlType());
            if (field.required) {
                try buf.appendSlice(self.allocator, " NOT NULL");
            }
        }

        // Fixed trailing columns
        try buf.appendSlice(self.allocator, ",\n  created_at INTEGER NOT NULL");
        try buf.appendSlice(self.allocator, ",\n  updated_at INTEGER NOT NULL");

        // Primary key constraint
        try buf.appendSlice(self.allocator, ",\n  PRIMARY KEY (id, namespace_id)");

        // FOREIGN KEY constraints
        for (table.fields) |field| {
            if (field.references) |ref| {
                try buf.appendSlice(self.allocator, ",\n  FOREIGN KEY (");
                try buf.appendSlice(self.allocator, field.name);
                try buf.appendSlice(self.allocator, ") REFERENCES ");
                try buf.appendSlice(self.allocator, ref);
                try buf.appendSlice(self.allocator, "(id)");
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
        try buf.appendSlice(self.allocator, ";\nCREATE INDEX IF NOT EXISTS idx_");
        try buf.appendSlice(self.allocator, table.name);
        try buf.appendSlice(self.allocator, "_namespace_id ON ");
        try buf.appendSlice(self.allocator, table.name);
        try buf.appendSlice(self.allocator, "(namespace_id)");

        // ── CREATE INDEX for each indexed field ───────────────────────────────
        for (table.fields) |field| {
            if (field.indexed) {
                try buf.appendSlice(self.allocator, ";\nCREATE INDEX IF NOT EXISTS idx_");
                try buf.appendSlice(self.allocator, table.name);
                try buf.append(self.allocator, '_');
                try buf.appendSlice(self.allocator, field.name);
                try buf.appendSlice(self.allocator, " ON ");
                try buf.appendSlice(self.allocator, table.name);
                try buf.append(self.allocator, '(');
                try buf.appendSlice(self.allocator, field.name);
                try buf.append(self.allocator, ')');
            }
        }

        try buf.append(self.allocator, ';');

        return buf.toOwnedSlice(self.allocator);
    }
};
