#!/usr/bin/env python3
"""Check that the simulation produces exactly the expected output, on any operating system.

The world's starting state is deterministic, so these byte totals must match on every platform
and with any SIMD tier that uses the same integration kernel. A mismatch means a shared kernel
behaves differently somewhere.

    python tests/check_bytes.py
"""
import os
import pathlib
import re
import subprocess
import sys

BUILD = pathlib.Path(__file__).resolve().parent.parent / "build"
EXE = BUILD / ("mmoserver.exe" if os.name == "nt" else "mmoserver")

# players, ticks, threads, world: expected snapshot bytes, measured on Windows
EXPECTED = {(20000, 2000, 4, 1772): 10494844640}
# 0 scalar uses different rounding when integrating, so it is checked for sanity only
TIERS = {1: "AVX2", 2: "AVX-512", 3: "chosen live"}

failed = False
for (players, ticks, threads, world), expected in EXPECTED.items():
    for tier, label in TIERS.items():
        out = subprocess.run(
            [str(EXE), "bench", str(players), str(ticks), str(threads), str(world), "50", "30",
             "27000", "1", "1", str(tier)],
            capture_output=True, text=True, check=True).stdout
        got = int(re.search(r"snapshot bytes\s*:\s*(\d+)", out)[1])
        used = re.search(r"query tier\s*:\s*(.+)", out)[1].strip()
        ok = got == expected
        failed |= not ok
        print(f"{'ok  ' if ok else 'FAIL'} requested {label:<12} ran {used:<24} {got} bytes"
              + ("" if ok else f", expected {expected}"))

print("FAILED" if failed else "all totals match")
sys.exit(1 if failed else 0)
