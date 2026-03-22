#!/bin/bash
# Round-robin fuzzer: runs each target for SLOT_SECS, then rotates.
# Maximizes single-core performance on resource-limited systems.
#
# Usage: round_robin.sh [slot_duration_secs]
# Default: 3600 (1 hour per target)
set -euo pipefail

SLOT="${1:-3600}"

TARGETS=(
    "ucnv_2022|/app/workspace/harnesses/ucnv_2022/harness_bin|/app/dicts/ucnv_2022.dict"
    "ucnv_mbcs|/app/workspace/harnesses/ucnv_mbcs/harness_bin|/app/dicts/ucnv_mbcs.dict"
    "ucnv_scsu|/app/workspace/harnesses/ucnv_scsu/harness_bin|/app/dicts/ucnv_scsu.dict"
)

ROUND=1
while true; do
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo " Round ${ROUND} — ${SLOT}s per target"
    echo "══════════════════════════════════════════════════════════"

    for entry in "${TARGETS[@]}"; do
        IFS='|' read -r TARGET BINARY DICT <<< "$entry"

        if [ ! -f "$BINARY" ]; then
            echo "[!] Binary not found: ${BINARY}, skipping ${TARGET}"
            continue
        fi

        echo ""
        echo "── [Round ${ROUND}] ${TARGET} for ${SLOT}s ──"
        bash /app/scripts/fuzz.sh "$BINARY" "$TARGET" "$SLOT" "$DICT" || true
        echo ""
        echo "[+] ${TARGET} slot complete."
    done

    ROUND=$((ROUND + 1))
done
