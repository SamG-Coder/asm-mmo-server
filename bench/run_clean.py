#!/usr/bin/env python3
"""Full re-measure on a machine that may not stay quiet.

A monitor logs any other process using more than one core. An end-to-end run that overlaps
such activity is discarded and repeated, and a result that never got a clean attempt is
marked with *. Each figure comes from CLEAN_RUNS runs.

    python bench/run_clean.py
"""
import datetime
import math
import os
import pathlib
import re
import statistics
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
LOG = BUILD / "load_clean.log"
RADIUS, VISIBLE, HZ, SECONDS, PORT, THREADS = 50, 50, 30, 10, 27300, 4
CLEAN_RUNS, MAX_ATTEMPTS = 3, 8
discarded = 0


def say(*args):
    print(*args, flush=True)


def interference(start, end):
    """Monitor lines covering this run. Each line describes the 5 s before its timestamp."""
    hits = []
    for line in LOG.read_text().splitlines():
        m = re.match(r"(\d\d):(\d\d):(\d\d) (.+)", line)
        if m:
            t = start.replace(hour=int(m[1]), minute=int(m[2]), second=int(m[3]), microsecond=0)
            if start <= t <= end + datetime.timedelta(seconds=5):
                hits.append(m[4])
    return hits


def stats(text):
    return {k.strip(): v.strip() for k, v in re.findall(r"^([^:\n]+?)\s*:\s*(.+)$", text, re.M)}


def once(exe, players, first_core):
    world = round(math.sqrt(players * math.pi * RADIUS**2 / VISIBLE))
    client_cpu = "0" if first_core else str(os.cpu_count() - 2)
    server = subprocess.Popen(
        [str(BUILD / exe), "serve", str(players), str(SECONDS + 2), str(THREADS), str(world),
         str(RADIUS), str(HZ), str(PORT), str(first_core), "1"],
        stdout=subprocess.PIPE, text=True)
    time.sleep(0.5)
    client = subprocess.run(
        [str(BUILD / "loadgen.exe"), str(players), str(players), str(THREADS), str(HZ),
         str(SECONDS), str(PORT), client_cpu], capture_output=True, text=True)
    out, _ = server.communicate(timeout=60)
    s, c = stats(out), stats(client.stdout)
    return {
        "delivery": float(c["delivery"].rstrip("%")),
        "p50": int(s["tick p50 us"]) / 1000,
        "p99": int(s["tick p99 us"]) / 1000,
        "over": int(s["tick overruns"]),
        "pps": int(c["inputs sent"].split("(")[1].split("/")[0])
        + int(c["snapshots recv"].split("(")[1].split("/")[0]),
        "rtt": int(c["round trip p99"].split()[0]) / 1000,
    }


def measure(exe, players, first_core):
    """Collect CLEAN_RUNS runs free of outside load, preferring clean over complete."""
    global discarded
    clean, dirty = [], []
    for _ in range(MAX_ATTEMPTS):
        if len(clean) == CLEAN_RUNS:
            break
        start = datetime.datetime.now().replace(microsecond=0)
        result = once(exe, players, first_core)
        end = datetime.datetime.now()
        time.sleep(6)                   # let the monitor finish the window covering this run
        hits = interference(start, end)
        if hits:
            discarded += 1
            dirty.append(result)
            say(f"   discarded {exe} {players}: {hits[0]}")
        else:
            clean.append(result)
    runs = clean if clean else dirty
    summary = {k: statistics.median(r[k] for r in runs) for k in runs[0]}
    summary["p99min"] = min(r["p99"] for r in runs)
    summary["p99max"] = max(r["p99"] for r in runs)
    summary["delmin"] = min(r["delivery"] for r in runs)
    summary["mark"] = "" if len(clean) == CLEAN_RUNS else f"* ({len(clean)} clean)"
    return summary


def row(players, r):
    say(f"{players:>8} {r['delivery']:>8.2f}% ({r['delmin']:>6.2f}) {r['p50']:>8.1f} "
        f"{r['p99']:>8.1f} [{r['p99min']:.1f}-{r['p99max']:.1f}] {r['over']:>5.0f} "
        f"{r['pps']:>11,.0f} {r['rtt']:>8.1f} {r['mark']}")


HEADER = (f"{'players':>8} {'delivery (min)':>18} {'p50 ms':>8} {'p99 ms [range]':>22} "
          f"{'over':>5} {'packets/s':>11} {'rtt p99':>8}")

watcher = subprocess.Popen(
    ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
     str(ROOT / "bench" / "watch_load.ps1"), "7200", str(LOG)],
    creationflags=subprocess.CREATE_NO_WINDOW)
time.sleep(6)
try:
    say("=== sendto vs RIO, both with workers from core 0 ===")
    for players in (5000, 10000, 15000, 20000, 30000):
        for label, exe in (("sendto", "mmoserver_sendto.exe"), ("RIO", "mmoserver.exe")):
            say(label)
            say(HEADER)
            row(players, measure(exe, players, 0))

    say("\n=== real limit: RIO, workers from core 1 (the new default) ===")
    say(HEADER)
    for players in (5000, 10000, 15000, 20000, 25000, 30000, 40000):
        row(players, measure("mmoserver.exe", players, 1))

    say(f"\n{discarded} runs discarded for outside load")

    say("\n=== simulation benchmarks (median of 7, so isolated interference is tolerated) ===")
    start = datetime.datetime.now().replace(microsecond=0)
    bench = subprocess.run([sys.executable, str(ROOT / "bench" / "run_bench.py")],
                           capture_output=True, text=True)
    say(bench.stdout)
    hits = interference(start, datetime.datetime.now())
    say(f"outside load seen during simulation benchmarks: {len(hits)} samples "
        f"{sorted(set(h.split('=')[0] for h in hits))}")
finally:
    watcher.kill()
