#!/usr/bin/env python3
"""Headless benchmark suite: assembly vs C, then player and thread scaling.

Every result is the median of RUNS runs. World size keeps about 50 entities visible
per player at every player count. Network I/O is excluded here; see tools/loadgen.c.

    python bench/run_bench.py
"""
import math
import pathlib
import re
import statistics
import subprocess

BUILD = pathlib.Path(__file__).resolve().parent.parent / "build"
RADIUS = 50
VISIBLE = 50
RUNS = 7


def world_for(players):
    return round(math.sqrt(players * math.pi * RADIUS**2 / VISIBLE))


def ticks_for(players):
    return max(30, 10_000_000 // players)


def run(args):
    out = subprocess.run([str(a) for a in args], capture_output=True, text=True, check=True).stdout
    return {k.strip(): int(v) for k, v in re.findall(r"^([^:\n]+?)\s*:\s*(\d+)\s*$", out, re.M)}


def median_of(args):
    results = [run(args) for _ in range(RUNS)]
    return {k: statistics.median(r[k] for r in results) for k in results[0]}


def asm(players, threads):
    return median_of([BUILD / "mmoserver.exe", "bench", players, ticks_for(players),
                      threads, world_for(players), RADIUS])


def c(name, players):
    return median_of([BUILD / name, players, ticks_for(players), world_for(players), RADIUS])


print(f"median of {RUNS} runs; ~{VISIBLE} entities visible per player\n")

print("assembly vs C, one thread")
print(f"{'players':>9} {'implementation':<22} {'ns/player/tick':>15} {'tick avg us':>12} {'p99 us':>9}")
for n in (10_000, 100_000, 1_000_000):
    for label, res in (("assembly", asm(n, 1)),
                       ("C + AVX2 intrinsics", c("baseline_intrin.exe", n)),
                       ("plain C (clang -O3)", c("baseline_c.exe", n))):
        print(f"{n:>9} {label:<22} {res['ns/player/tick']:>15.0f} "
              f"{res['tick avg us']:>12.0f} {res['tick p99 us']:>9.0f}")

print("\nthread scaling, assembly")
print(f"{'players':>9} {'threads':>8} {'tick avg us':>12} {'p99 us':>9} {'grid us':>9} "
      f"{'speedup':>8} {'max players @30Hz':>18}")
for n in (100_000, 1_000_000):
    base = None
    for threads in (1, 2, 4, 8):
        res = asm(n, threads)
        base = base or res["tick avg us"]
        fit = int(n * (1_000_000 / 30) / res["tick p99 us"])
        print(f"{n:>9} {threads:>8} {res['tick avg us']:>12.0f} {res['tick p99 us']:>9.0f} "
              f"{res['grid build us']:>9.0f} {base / res['tick avg us']:>8.2f} {fit:>18,}")
