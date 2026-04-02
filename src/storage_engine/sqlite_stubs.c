#include <sqlite3.h>

// =============================================================================
// SQLite Helpers (Bypass Zig Alignment Safety for Sentinels)
// =============================================================================
// These helpers allow binding text and blobs with SQLITE_TRANSIENT (-1) 
// without passing the unaligned pointer through Zig's safety-checked system.

int zyncbase_sqlite3_bind_text_transient(sqlite3_stmt *pStmt, int i, const void *zData, int nData) {
    return sqlite3_bind_text(pStmt, i, zData, nData, SQLITE_TRANSIENT);
}

int zyncbase_sqlite3_bind_blob_transient(sqlite3_stmt *pStmt, int i, const void *zData, int nData) {
    return sqlite3_bind_blob(pStmt, i, zData, nData, SQLITE_TRANSIENT);
}
