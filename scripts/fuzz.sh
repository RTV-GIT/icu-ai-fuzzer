#!/bin/bash
# Usage: fuzz.sh <binary> <target_name> [duration_secs] [dict_path]
# Runs libFuzzer with seed corpus + dictionary + corpus backup.
set -euo pipefail

BINARY="${1:?Usage: fuzz.sh <binary> <target_name> [duration_secs] [dict_path]}"
TARGET="${2:?Usage: fuzz.sh <binary> <target_name> [duration_secs] [dict_path]}"
DURATION="${3:-0}"  # 0 = run forever
DICT="${4:-}"

ICU_SRC="${ICU_SRC:-/opt/icu-src}"
CORPUS_DIR="/app/workspace/corpus/${TARGET}"
CRASH_DIR="/app/workspace/crashes/${TARGET}"
BACKUP_DIR="/app/workspace/corpus_backup/${TARGET}"

mkdir -p "$CORPUS_DIR" "$CRASH_DIR" "$BACKUP_DIR"

# ── Restore corpus from backup (if container restarted) ──────────────
if [ -d "$BACKUP_DIR" ] && [ "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
    RESTORED=$(cp -n "$BACKUP_DIR"/* "$CORPUS_DIR/" 2>/dev/null && echo "ok" || echo "none")
    [ "$RESTORED" = "ok" ] && echo "[+] Restored corpus from backup"
fi

# ── Seed corpus from ICU test data ───────────────────────────────────
TESTDATA="${ICU_SRC}/icu4c/source/test/testdata"
if [ -d "$TESTDATA" ]; then
    SEEDED=0
    for f in "$TESTDATA"/*; do
        [ -f "$f" ] || continue
        SIZE=$(stat -c%s "$f" 2>/dev/null || echo 99999)
        if [ "$SIZE" -lt 10240 ]; then
            cp -n "$f" "$CORPUS_DIR/" 2>/dev/null && SEEDED=$((SEEDED+1)) || true
        fi
    done
    [ "$SEEDED" -gt 0 ] && echo "[+] Seeded ${SEEDED} files from ICU testdata"
fi

# Ensure at least one seed
if [ -z "$(ls -A "$CORPUS_DIR" 2>/dev/null)" ]; then
    printf '\x00\x00\x00\x00\x00\x00\x00\x00' > "$CORPUS_DIR/empty"
fi

# ── Background corpus backup (every 10 minutes) ─────────────────────
(
    while true; do
        sleep 600
        rsync -a --quiet "$CORPUS_DIR/" "$BACKUP_DIR/" 2>/dev/null || true
    done
) &
BACKUP_PID=$!
trap "kill $BACKUP_PID 2>/dev/null; exit" EXIT INT TERM

echo "[+] Corpus backup running (PID=${BACKUP_PID}, every 10min → ${BACKUP_DIR})"

# ── Build fuzzer command ─────────────────────────────────────────────
CMD=("$BINARY" "$CORPUS_DIR"
     "-artifact_prefix=${CRASH_DIR}/"
     "-max_len=4096"
     "-print_final_stats=1")

if [ "$DURATION" -gt 0 ]; then
    CMD+=("-max_total_time=${DURATION}")
fi

if [ -n "$DICT" ] && [ -f "$DICT" ]; then
    CMD+=("-dict=${DICT}")
    echo "[+] Dictionary: ${DICT}"
fi

echo "[+] Fuzzing ${TARGET} (duration: ${DURATION}s, 0=infinite)"
echo "[+] CMD: ${CMD[*]}"
echo "[+] Crashes → ${CRASH_DIR}"
echo "────────────────────────────────────────"

export ASAN_OPTIONS="abort_on_error=1:symbolize=1:detect_leaks=0"
"${CMD[@]}" || true
