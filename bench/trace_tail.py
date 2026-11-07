#!/usr/bin/env python3
"""Explain slow ticks by comparing them with typical ticks from the same runs.

    python bench/trace_tail.py [players] [runs]

Environment: MMO_SEND_EVERY (default 2), MMO_FIRST_CORE (default 1), MMO_TIER (default 3),
MMO_SERVER_HIGH (default 1), and MMO_HIGH=1 for a high-priority load generator.
"""
import csv
import math
import os
import pathlib
import statistics
import struct
import subprocess
import sys
import time

BUILD = pathlib.Path(__file__).resolve().parent.parent / "build"
PLAYERS = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 4
THREADS, HZ, SECONDS, RADIUS, VISIBLE, PORT = 4, 30, 10, 50, 50, 27400
SLOW_MS = 25.0
EVERY = os.environ.get("MMO_SEND_EVERY", "2")
FIRST_CORE = os.environ.get("MMO_FIRST_CORE", "1")
TIER = os.environ.get("MMO_TIER", "3")
SERVER_HIGH = os.environ.get("MMO_SERVER_HIGH", "1")
PRIORITY = subprocess.HIGH_PRIORITY_CLASS if os.environ.get("MMO_HIGH") else 0
CLIENT_CPU = "0" if FIRST_CORE != "0" else str(os.cpu_count() - 2)


def run_once():
    world = round(math.sqrt(PLAYERS * math.pi * RADIUS**2 / VISIBLE))
    server = subprocess.Popen(
        [str(BUILD / "mmoserver_trace.exe"), "serve", str(PLAYERS), str(SECONDS + 2), str(THREADS),
         str(world), str(RADIUS), str(HZ), str(PORT), FIRST_CORE, EVERY, TIER, SERVER_HIGH],
        stdout=subprocess.DEVNULL, cwd=BUILD)
    time.sleep(0.5)
    ctrace = BUILD / "client_trace.csv"
    client = subprocess.run(
        [str(BUILD / "loadgen.exe"), str(PLAYERS), str(PLAYERS), str(THREADS), str(HZ), str(SECONDS),
         str(PORT), CLIENT_CPU, EVERY],
        capture_output=True, text=True, creationflags=PRIORITY,
        env={**os.environ, "LOADGEN_TRACE": str(ctrace)})
    server.wait(timeout=60)
    delivery = next(l for l in client.stdout.splitlines() if l.startswith("delivery")).split()[-1]
    data = (BUILD / "trace.bin").read_bytes()
    threads, count, freq, rec = struct.unpack_from("<QQQQ", data)
    ticks = []
    for t in range(count):
        workers = []
        for w in range(threads):
            v = struct.unpack_from("<12Q", data, 64 + (t * threads + w) * rec)
            workers.append((v[:6], v[6:]))
        ticks.append(workers)
    with open(ctrace) as f:
        bursts = sorted((int(r["start"]), int(r["send_end"])) for r in csv.DictReader(f))
    return ticks, freq, bursts, delivery


def measure(ticks, freq, bursts):
    ms = lambda q: q * 1000.0 / freq
    rates = sorted(w[1][2] / ms(w[1][1] - w[1][0]) for tick in ticks for w in tick if w[1][3] > 100)
    full_speed = rates[len(rates) // 2]
    rows = []
    for i, tick in enumerate(ticks):
        if not any(w[1][3] for w in tick):
            continue                    # no client connected yet
        begin = min(w[0][0] for w in tick)
        rx_end = max(w[0][1] for w in tick)
        tx_begin = min(w[1][0] for w in tick)
        end = max(w[1][1] for w in tick)
        slowest = max(range(len(tick)), key=lambda k: tick[k][1][1] - tick[k][1][0])
        p = tick[slowest][1]
        wall = ms(p[1] - p[0])
        cpu = p[2] / full_speed
        overlap = sum(max(0, min(e, end) - max(s, begin)) for s, e in bursts) / max(1, end - begin) / THREADS
        rxw = max(range(len(tick)), key=lambda k: tick[k][0][1] - tick[k][0][0])
        q = tick[rxw][0]
        rx_wall = ms(q[1] - q[0])
        rx_cpu = q[2] / full_speed
        rows.append({
            "rx_worker": rxw,
            "rx_wall": rx_wall,
            "rx_cpu": rx_cpu,
            "rx_off": max(0.0, rx_wall - rx_cpu),
            "rx_commit": ms(q[4]),
            "rx_commit_max": ms(q[5]),
            "rx_worker_pkts": q[3],
            "tick": i,
            "total": ms(end - begin),
            "rx": ms(rx_end - begin),
            "grid": ms(tx_begin - rx_end),
            "tx": ms(end - tx_begin),
            "start_spread": ms(max(w[1][0] for w in tick) - tx_begin),
            "rx_start_spread": ms(max(w[0][0] for w in tick) - begin),
            "late_start": max(ms(max(w[1][0] for w in tick) - tx_begin), ms(max(w[0][0] for w in tick) - begin)),
            "slow_worker": slowest,
            "wall": wall,
            "cpu": cpu,
            "off": max(0.0, wall - cpu),
            "commit": ms(p[4]),
            "commit_max": ms(p[5]),
            "imbalance": wall - statistics.median(ms(w[1][1] - w[1][0]) for w in tick),
            "overlap": 100 * overlap,
            "rx_pkts": sum(w[0][3] for w in tick),
            "profiling": (i - 8) % 516 < 4 and i >= 8,
        })
    return rows


everything = []
for run in range(RUNS):
    ticks, freq, bursts, delivery = run_once()
    rows = measure(ticks, freq, bursts)
    slow = [r for r in rows if r["total"] > SLOW_MS]
    print(f"run {run + 1}: delivery {delivery}, {len(rows)} ticks, {len(slow)} over {SLOW_MS:.0f} ms, "
          f"worst {max(r['total'] for r in rows):.1f} ms", flush=True)
    everything += rows
    time.sleep(0.5)

slow = [r for r in everything if r["total"] > SLOW_MS]
typical = [r for r in everything if r["total"] <= SLOW_MS]
print(f"\n{'median of':<28} {'typical':>9} {'slow':>9}   ({len(typical)} and {len(slow)} ticks)")
for key, label in (("total", "tick total, ms"), ("rx", "  input phase, ms"), ("grid", "  grid build, ms"),
                   ("tx", "  snapshot phase, ms"), ("start_spread", "  last worker's late start, ms"),
                   ("late_start", "latest start, either phase, ms"),
                   ("wall", "slowest worker, wall ms"), ("cpu", "slowest worker, CPU ms"),
                   ("off", "slowest worker, off-CPU ms"), ("commit", "slowest worker, commits ms"),
                   ("commit_max", "longest single commit, ms"), ("imbalance", "slowest minus median worker"),
                   ("overlap", "overlap with client sends, %"), ("rx_pkts", "inputs drained"),
                   ("rx_wall", "input: slowest worker wall ms"), ("rx_cpu", "input: its CPU ms"),
                   ("rx_off", "input: its off-CPU ms"), ("rx_commit", "input: its commit ms"),
                   ("rx_worker_pkts", "input: its packets")):
    t = statistics.median(r[key] for r in typical) if typical else 0
    s = statistics.median(r[key] for r in slow) if slow else 0
    print(f"{label:<28} {t:>9.1f} {s:>9.1f}")

print("\nslowest worker in slow ticks:",
      {k: sum(r["slow_worker"] == k for r in slow) for k in range(THREADS)})
print("slowest input worker in slow ticks:",
      {k: sum(r["rx_worker"] == k for r in slow) for k in range(THREADS)})
print("slow ticks that were profiling ticks:", sum(r["profiling"] for r in slow), "of", len(slow))
position = [r["tick"] for r in slow]
print("position in run (first 40):", position[:40])
print("\nworst 10 ticks:")
print(f"{'tick':>5} {'total':>7} {'rx':>6} {'grid':>6} {'tx':>6} {'wrk':>4} {'wall':>6} {'cpu':>6} {'off':>6} "
      f"{'commit':>7} {'maxcom':>7} {'overlap':>8} | {'rxwrk':>5} {'rxwall':>7} {'rxcpu':>6} {'rxcom':>6} {'rxpkts':>6}")
for r in sorted(everything, key=lambda r: -r["total"])[:10]:
    print(f"{r['tick']:>5} {r['total']:>7.1f} {r['rx']:>6.1f} {r['grid']:>6.1f} {r['tx']:>6.1f} "
          f"{r['slow_worker']:>4} {r['wall']:>6.1f} {r['cpu']:>6.1f} {r['off']:>6.1f} {r['commit']:>7.1f} "
          f"{r['commit_max']:>7.1f} {r['overlap']:>7.0f}% | {r['rx_worker']:>5} {r['rx_wall']:>7.1f} {r['rx_cpu']:>6.1f} "
          f"{r['rx_commit']:>6.1f} {r['rx_worker_pkts']:>6}")
over = [r for r in everything if r["total"] > 33]
print(f"\n{len(over)} of {len(everything)} ticks over the 33 ms budget")
late = [r for r in everything if r["late_start"] > 5]
kicked = [r for r in everything if r["off"] > 5]
print(f"SUMMARY over33={len(over)} over25={len(slow)} worst={max(r['total'] for r in everything):.1f} "
      f"p50={statistics.median(r['total'] for r in everything):.1f} "
      f"late_start_over_5ms={len(late)} off_cpu_over_5ms={len(kicked)} ticks={len(everything)}")
