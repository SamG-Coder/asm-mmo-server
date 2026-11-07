#!/usr/bin/env python3
"""Capture tick stalls: run the trace build under load and explain the slow ticks.

For each slow tick this shows which worker and phase was slow, and whether that thread
was using the CPU (cycles) or waiting. Timestamps share one clock with the load
generator, so stalls on both sides can be lined up.

    python bench/diagnose.py [players] [runs] [threads]
"""
import csv
import math
import os
import pathlib
import struct
import subprocess
import sys
import time

BUILD = pathlib.Path(__file__).resolve().parent.parent / "build"
PLAYERS = int(sys.argv[1]) if len(sys.argv) > 1 else 15000
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 6
THREADS = int(sys.argv[3]) if len(sys.argv) > 3 else 4
HZ, SECONDS, RADIUS, VISIBLE, PORT = 30, 10, 50, 50, 27200
SLOW_MS = 40.0
EXE = os.environ.get("MMO_EXE", "mmoserver_trace.exe")
# MMO_HIGH=1 runs server and client at high priority, to test for CPU competition.
PRIORITY = subprocess.HIGH_PRIORITY_CLASS if os.environ.get("MMO_HIGH") else 0
# MMO_FIRST_CORE=0 puts server workers on logical CPU 0 upward, instead of the default 1.
FIRST_CORE = os.environ.get("MMO_FIRST_CORE", "1")
CLIENT_CPU = ["0"] if FIRST_CORE != "0" else [str(os.cpu_count() - 2)]


def load_trace():
    data = (BUILD / "trace.bin").read_bytes()
    threads, ticks, freq, rec = struct.unpack_from("<QQQQ", data)
    out = []
    for t in range(ticks):
        workers = []
        for w in range(threads):
            v = struct.unpack_from("<12Q", data, 64 + (t * threads + w) * rec)
            workers.append({"p1": v[:6], "p2": v[6:]})
        out.append(workers)
    return out, freq


def client_trace(path):
    with open(path) as f:
        return [{k: int(v) for k, v in row.items()} for row in csv.DictReader(f)]


world = round(math.sqrt(PLAYERS * math.pi * RADIUS**2 / VISIBLE))
for run in range(RUNS):
    server = subprocess.Popen(
        [str(BUILD / EXE), "serve", str(PLAYERS), str(SECONDS + 2), str(THREADS),
         str(world), str(RADIUS), str(HZ), str(PORT), FIRST_CORE, "1"],
        stdout=subprocess.DEVNULL, cwd=BUILD, creationflags=PRIORITY)
    time.sleep(0.5)
    ctrace = BUILD / "client_trace.csv"
    client = subprocess.run(
        [str(BUILD / "loadgen.exe"), str(PLAYERS), str(PLAYERS), str(THREADS), str(HZ),
         str(SECONDS), str(PORT)] + CLIENT_CPU,
        capture_output=True, text=True, creationflags=PRIORITY,
        env={**os.environ, "LOADGEN_TRACE": str(ctrace)})
    server.wait(timeout=60)
    delivery = next(l for l in client.stdout.splitlines() if l.startswith("delivery")).split()[-1]

    ticks, freq = load_trace()
    ms = lambda q: q * 1000.0 / freq
    t0 = ticks[0][0]["p1"][0]
    # A fully busy thread's cycles per ms of wall time, from the median snapshot phase.
    rates = sorted(w["p2"][2] / ms(w["p2"][1] - w["p2"][0])
                   for tick in ticks for w in tick if w["p2"][3] > 100)
    full_speed = rates[len(rates) // 2] if rates else 1

    slow = []
    for i, tick in enumerate(ticks):
        begin = min(w["p1"][0] for w in tick)
        end = max(w["p2"][1] for w in tick)
        if ms(end - begin) > SLOW_MS:
            slow.append((i, begin, end, tick))
    # Time workers were inside a phase but not running on a CPU, across the whole run.
    waited = [0.0] * len(ticks[0])
    for tick in ticks:
        for wi, w in enumerate(tick):
            for p in (w["p1"], w["p2"]):
                waited[wi] += max(0.0, ms(p[1] - p[0]) - p[2] / full_speed)
    worst = max(ms(max(w["p2"][1] for w in t) - min(w["p1"][0] for w in t)) for t in ticks)
    print(f"\n=== run {run + 1}: delivery {delivery}, {len(ticks)} ticks, {len(slow)} slow "
          f"(>{SLOW_MS:.0f} ms), worst {worst:.0f} ms; off-CPU per worker (ms): "
          + " ".join(f"{x:.0f}" for x in waited))
    if os.environ.get("MMO_BRIEF"):
        time.sleep(0.5)
        continue
    for i, begin, end, tick in slow[:12]:
        print(f" tick {i:4} at {ms(begin - t0):7.0f} ms, {ms(end - begin):6.1f} ms total")
        for wi, w in enumerate(tick):
            for name, p in (("rx", w["p1"]), ("tx", w["p2"])):
                wall = ms(p[1] - p[0])
                if wall < 15:
                    continue
                busy = p[2] / full_speed
                print(f"   worker {wi} {name}: wall {wall:6.1f} ms, cpu ~{busy:6.1f} ms "
                      f"({100 * busy / wall:3.0f}%), {p[3]:5} pkts, commits {ms(p[4]):6.1f} ms "
                      f"(longest {ms(p[5]):6.1f})")
    # What the client threads were doing during those stalls.
    rows = client_trace(ctrace)
    overlaps = {}
    for i, begin, end, _ in slow:
        for r in rows:
            if r["send_end"] > begin and r["start"] < end:
                d = ms(r["send_end"] - r["start"])
                if d > 30:
                    overlaps[(r["thread"], r["period"])] = d
    if overlaps:
        print(" client send bursts >30 ms overlapping those ticks:",
              ", ".join(f"t{k[0]}#{k[1]}={v:.0f}ms" for k, v in list(overlaps.items())[:10]))
    sends = sorted(ms(r["send_end"] - r["start"]) for r in rows)
    print(f" client send burst p50 {sends[len(sends) // 2]:.1f} ms, max {sends[-1]:.1f} ms")
    time.sleep(0.5)
