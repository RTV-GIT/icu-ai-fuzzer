#!/usr/bin/env python3
"""Crash reproducer, deduplicator, and GDB info extractor.

Usage:
    python3 reproduce.py <binary> <target_name>

Scans workspace/crashes/<target_name>/ for crash files, reproduces each,
deduplicates by ASan stack hash, runs GDB extraction on unique crashes,
and writes structured results to workspace/crashes/<target_name>/results.json
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from gdb_extractor import GDBExtractor

CRASH_BASE = Path("/app/workspace/crashes")
TOP_N_FRAMES = 5


def extract_stack_hash(asan_log: str) -> str | None:
    frames = re.findall(r"#\d+\s+0x[0-9a-f]+\s+in\s+(\S+)", asan_log)
    if not frames:
        return None
    key = "\n".join(frames[:TOP_N_FRAMES])
    return hashlib.sha256(key.encode()).hexdigest()[:16]


def detect_bug_class(asan_log: str) -> str:
    patterns = [
        ("heap-buffer-overflow", "heap-buffer-overflow"),
        ("stack-buffer-overflow", "stack-buffer-overflow"),
        ("heap-use-after-free", "use-after-free"),
        ("double-free", "double-free"),
        ("SEGV on unknown address", "null-deref / wild-pointer"),
        ("integer overflow", "integer-overflow"),
        ("out of memory", "oom"),
    ]
    for pattern, label in patterns:
        if pattern.lower() in asan_log.lower():
            return label
    return "unknown"


def main() -> None:
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <binary> <target_name>")
        sys.exit(1)

    binary = sys.argv[1]
    target = sys.argv[2]
    crash_dir = CRASH_BASE / target

    if not crash_dir.is_dir():
        print(f"[-] No crash dir: {crash_dir}")
        sys.exit(1)

    crash_files = sorted(crash_dir.glob("crash-*")) + sorted(crash_dir.glob("oom-*"))
    if not crash_files:
        print(f"[-] No crash files in {crash_dir}")
        sys.exit(0)

    print(f"[+] Found {len(crash_files)} raw crash files")

    env = os.environ.copy()
    env["ASAN_OPTIONS"] = "abort_on_error=1:symbolize=1:detect_leaks=0"

    gdb = GDBExtractor()
    seen_hashes: set[str] = set()
    unique_crashes: list[dict] = []

    for cf in crash_files:
        # Reproduce
        try:
            result = subprocess.run(
                [binary, str(cf)],
                capture_output=True, text=True, timeout=30, env=env,
            )
        except subprocess.TimeoutExpired:
            print(f"  [!] Timeout reproducing {cf.name}, skipping")
            continue

        asan_log = result.stderr

        # Dedup
        h = extract_stack_hash(asan_log)
        if h and h in seen_hashes:
            print(f"  [-] Duplicate: {cf.name} (hash={h})")
            continue
        if h:
            seen_hashes.add(h)

        bug_class = detect_bug_class(asan_log)
        print(f"  [+] Unique: {cf.name} | {bug_class} | hash={h}")

        # GDB extraction
        gdb_info = {}
        try:
            gdb_info = gdb.extract(binary, str(cf))
        except Exception as e:
            print(f"  [!] GDB failed for {cf.name}: {e}")

        unique_crashes.append({
            "crash_file": str(cf),
            "crash_name": cf.name,
            "bug_class": bug_class,
            "stack_hash": h,
            "exit_code": result.returncode,
            "asan_log": asan_log,
            "gdb_registers": gdb_info.get("registers", ""),
            "gdb_backtrace": gdb_info.get("backtrace", ""),
            "gdb_stack": gdb_info.get("stack", ""),
            "gdb_vmmap": gdb_info.get("vmmap", ""),
        })

    # Write results
    out_path = crash_dir / "results.json"
    out_path.write_text(json.dumps(unique_crashes, indent=2))
    print(f"\n[+] Unique crashes: {len(unique_crashes)} / {len(crash_files)}")
    print(f"[+] Results → {out_path}")

    # Also write a summary for quick reading
    summary_path = crash_dir / "summary.txt"
    with open(summary_path, "w") as f:
        for i, c in enumerate(unique_crashes, 1):
            f.write(f"#{i} | {c['crash_name']} | {c['bug_class']} | hash={c['stack_hash']}\n")
    print(f"[+] Summary → {summary_path}")


if __name__ == "__main__":
    main()
