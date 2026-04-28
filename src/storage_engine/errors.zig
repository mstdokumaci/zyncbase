const std = @import("std");
const sqlite = @import("sqlite");

/// Specific error types for different database failure scenarios.
pub const StorageError = error{
    /// Database connection was lost
    ConnectionLost,
    /// Failed to reconnect after multiple attempts
    ReconnectionFailed,
    /// Database constraint was violated (e.g. unique constraint)
    ConstraintViolation,
    /// Disk is full, cannot write more data
    DiskFull,
    /// Database file is corrupted
    DatabaseCorrupted,
    /// Database is locked by another process
    DatabaseLocked,
    /// Invalid database operation
    InvalidOperation,
    /// Transaction is already active
    TransactionAlreadyActive,
    /// No active transaction
    NoActiveTransaction,
    /// Table not found in schema
    UnknownTable,
    /// Field not found in table schema
    UnknownField,
    /// Attempted to modify a protected/immutable system field
    ImmutableField,
    /// NOT NULL column received null value
    NullNotAllowed,
    /// Write blocked because migration is in progress
    MigrationInProgress,
    /// Field value type does not match schema
    TypeMismatch,
    /// Array field contains non-literal elements (maps, nested arrays)
    InvalidArrayElement,
    /// The provided data path is invalid (too short, too long, or malformed)
    InvalidPath,
    /// SQLite returned a different number of columns than schema metadata expects
    ColumnCountMismatch,
    /// Data directory is invalid or empty
    InvalidDataDir,
    /// Path is not a directory
    NotDir,
    /// Required condition value is missing
    MissingConditionValue,
    /// Low-level SQLite error that doesn't match specific classified types
    SQLiteError,
};

pub fn classifyError(err: anyerror) anyerror {
    return switch (err) {
        error.SQLiteConstraint => StorageError.ConstraintViolation,
        error.SQLiteFull => StorageError.DiskFull,
        error.SQLiteCorrupt, error.SQLiteNotADatabase => StorageError.DatabaseCorrupted,
        error.SQLiteBusy, error.SQLiteLocked => StorageError.DatabaseLocked,
        else => err,
    };
}

pub fn classifyStepError(db: *sqlite.Db) anyerror {
    const rc = sqlite.c.sqlite3_errcode(db.db);
    return switch (rc) {
        sqlite.c.SQLITE_CONSTRAINT => StorageError.ConstraintViolation,
        sqlite.c.SQLITE_FULL => StorageError.DiskFull,
        sqlite.c.SQLITE_CORRUPT, sqlite.c.SQLITE_NOTADB => StorageError.DatabaseCorrupted,
        sqlite.c.SQLITE_BUSY, sqlite.c.SQLITE_LOCKED => StorageError.DatabaseLocked,
        else => StorageError.SQLiteError,
    };
}

pub fn logDatabaseError(operation: []const u8, err: anyerror, context: []const u8) void {
    std.log.debug("Database error during {s}: {} - Context: {s}", .{ operation, err, context });
}
