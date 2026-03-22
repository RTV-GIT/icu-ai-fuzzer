"""GDB/pwndbg Automated Memory Extractor

Runs GDB with a crash input, extracts register state, stack dump,
and memory maps. Strips ANSI escape codes before returning clean text
suitable for LLM consumption.
"""

from __future__ import annotations

import re
import subprocess
import textwrap
from dataclasses import dataclass
from pathlib import Path

# Matches all ANSI escape sequences (colors, cursor movement, etc.)
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]|\x1b\].*?\x07")


def strip_ansi(text: str) -> str:
    return _ANSI_RE.sub("", text)


@dataclass
class GDBExtractor:
    """Extracts post-crash memory state via GDB + pwndbg."""

    gdb_path: str = "gdb"
    timeout_secs: int = 30

    def extract(self, binary: str, crash_input: str) -> dict[str, str]:
        """Run GDB on *binary* with *crash_input* and return extracted info.

        Returns dict with keys: registers, stack, backtrace, vmmap, raw.
        """
        gdb_script = textwrap.dedent(f"""\
            set pagination off
            set confirm off
            file {binary}
            run {crash_input}
            echo ===REGISTERS===\\n
            info registers
            echo ===BACKTRACE===\\n
            bt full
            echo ===STACK===\\n
            x/32gx $sp
            echo ===VMMAP===\\n
            info proc mappings
            echo ===END===\\n
            quit
        """)

        result = subprocess.run(
            [self.gdb_path, "-batch", "-x", "/dev/stdin"],
            input=gdb_script,
            capture_output=True,
            text=True,
            timeout=self.timeout_secs,
        )

        raw = strip_ansi(result.stdout + "\n" + result.stderr)

        return {
            "registers": self._extract_section(raw, "REGISTERS", "BACKTRACE"),
            "backtrace": self._extract_section(raw, "BACKTRACE", "STACK"),
            "stack": self._extract_section(raw, "STACK", "VMMAP"),
            "vmmap": self._extract_section(raw, "VMMAP", "END"),
            "raw": raw,
        }

    @staticmethod
    def _extract_section(text: str, start_marker: str, end_marker: str) -> str:
        pattern = f"==={start_marker}===\n(.*?)==={end_marker}==="
        m = re.search(pattern, text, re.DOTALL)
        return m.group(1).strip() if m else ""
