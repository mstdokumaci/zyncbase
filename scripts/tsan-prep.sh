#!/usr/bin/env bash
set -euo pipefail

# Zig 0.16.0's static libc++ archive defines __cxa_guard_acquire/release/abort as
# GLOBAL symbols in several members (iostream.o, ios.o, cxa_guard.o, ...). Linking
# with -fsanitize=thread can pull those members out, colliding with libtsan.a's own
# definitions -> "duplicate symbol definition: __cxa_guard_*" at link time. Whether
# the collision actually fires depends on link order, which varies per build (zig's
# -Z seed), so we patch unconditionally.
#
# Localizing the guard symbols keeps thread-safe statics working: the local
# definitions still guard within their own objects, and every external call
# resolves to libtsan's (which links first). Idempotent; harmless on archives that
# do not define the symbols or already have them local.
#
# Usage:
#   tsan-prep.sh            Patch archives for TSAN builds (saves backups).
#   tsan-prep.sh --restore  Restore original archives after TSAN builds.

cache_dir="${ZIG_GLOBAL_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/zig}"

if [[ "${1:-}" == "--restore" ]]; then
    count=0
    for archive in "$cache_dir"/o/*/libc++.a "$cache_dir"/o/*/libc++abi.a; do
        [ -f "$archive" ] || continue
        backup="${archive}.orig"
        if [ -f "$backup" ]; then
            mv "$backup" "$archive"
            count=$((count + 1))
        fi
    done
    echo "tsan-prep: restored $count archive(s)"
    exit 0
fi

# Populate zig's global cache: the libc++ archives are built before linking, so a
# link failure here is expected on unpatched caches and is ignored.
zig build test -Dsanitize=thread -Dtest-filter="__tsan_prep__" --summary none >/dev/null 2>&1 || true

# Patch: save originals, localize guard symbols.
count=0
for archive in "$cache_dir"/o/*/libc++.a "$cache_dir"/o/*/libc++abi.a; do
    [ -f "$archive" ] || continue
    backup="${archive}.orig"
    [ -f "$backup" ] || cp "$archive" "$backup"
    tmp_archive="${archive}.tsan-tmp"
    rm -f "$tmp_archive"
    llvm-objcopy --localize-symbol=__cxa_guard_acquire \
                 --localize-symbol=__cxa_guard_release \
                 --localize-symbol=__cxa_guard_abort \
                 "$archive" "$tmp_archive"
    mv "$tmp_archive" "$archive"
    count=$((count + 1))
done
echo "tsan-prep: localized __cxa_guard_* symbols in $count archive(s)"
echo "tsan-prep: run 'scripts/tsan-prep.sh --restore' after TSAN tests to fix non-TSAN builds"
