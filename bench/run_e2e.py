#!/usr/bin/env python3
"""End-to-end benchmark: real UDP over loopback at 30 Hz, every player a live client.

Server and load generator share one machine, on separate physical cores. Each player
sends one input and receives one snapshot per tick, with about 50 entities visible.

    python bench/run_e2e.py [threads] [player counts...]

Set MMO_EXE and MMO_LOADGEN to test other builds from the build folder.
"""
import math
import os
import pathlib
import re
import subprocess
import sys
import time

BUILD = pathlib.Path(__file__).resolve().parent.parent / "build"
EXT = ".exe" if os.name == "nt" else ""
RADIUS, VISIBLE, HZ, SECONDS, PORT = 50, 50, 30, 10, 27100
THREADS = int(sys.argv[1]) if len(sys.argv) > 1 else 4
# MMO_FIRST_CORE=0 puts server workers on logical CPU 0 upward, instead of the default 1.
FIRST_CORE = os.environ.get("MMO_FIRST_CORE", "1")
CLIENT_CPU = ["0"] if FIRST_CORE != "0" else [str(os.cpu_count() - 2)]
# MMO_SEND_EVERY: send each player a snapshot every 1, 2 or 4 ticks.
EVERY = os.environ.get("MMO_SEND_EVERY", "2")
# MMO_INPUT_HZ: how often each client sends input. It must divide the snapshot rate evenly.
INPUT_HZ = int(os.environ.get("MMO_INPUT_HZ", HZ))
# MMO_SERVER_HIGH=0 runs the server at normal priority; MMO_CLIENT_HIGH=1 raises the generator.
SERVER_HIGH = os.environ.get("MMO_SERVER_HIGH", "1")
CLIENT_FLAGS = getattr(subprocess, "HIGH_PRIORITY_CLASS", 0) if os.environ.get("MMO_CLIENT_HIGH") else 0
COUNTS = [int(a) for a in sys.argv[2:]] or [1000, 5000, 10000, 20000, 40000, 80000]


def stats(text):
    return {k.strip(): v.strip() for k, v in re.findall(r"^([^:\n]+?)\s*:\s*(.+)$", text, re.M)}


print(f"{THREADS} server threads + {THREADS} client threads, {HZ} Hz, {SECONDS} s per run")
print(f"{'players':>8} {'inputs':>7} {'delivery':>9} {'tick p50':>9} {'tick p99':>9} {'overruns':>9} "
      f"{'pps in+out':>11} {'MB/s':>7} {'rtt p50':>9} {'rtt p99':>9} result")
for n in COUNTS:
    world = round(math.sqrt(n * math.pi * RADIUS**2 / VISIBLE))
    server = subprocess.Popen(
        [str(BUILD / os.environ.get("MMO_EXE", "mmoserver" + EXT)), "serve", str(n), str(SECONDS + 2), str(THREADS),
         str(world), str(RADIUS), str(HZ), str(PORT), FIRST_CORE, EVERY, "3", SERVER_HIGH],
        stdout=subprocess.PIPE, text=True)
    time.sleep(0.5)
    client = subprocess.run(
        [str(BUILD / os.environ.get("MMO_LOADGEN", "loadgen" + EXT)), str(n), str(n), str(THREADS), str(INPUT_HZ), str(SECONDS), str(PORT)] + CLIENT_CPU
        + [str(INPUT_HZ * int(EVERY) // HZ)],
        capture_output=True, text=True, creationflags=CLIENT_FLAGS)
    out, _ = server.communicate(timeout=60)
    s, c = stats(out), stats(client.stdout)
    pps = int(c["inputs sent"].split("(")[1].split("/")[0]) + int(c["snapshots recv"].split("(")[1].split("/")[0])
    print(f"{n:>8} {c['input rate']:>7} {c['delivery']:>9} {s['tick p50 us']:>9} {s['tick p99 us']:>9} "
          f"{s['tick overruns']:>9} {pps:>11,} {c['bandwidth'].split()[0]:>7} "
          f"{c['round trip p50'].split()[0]:>9} {c['round trip p99'].split()[0]:>9} "
          + ("PASS" if float(c["input rate"].rstrip("%")) >= 99 and float(c["delivery"].rstrip("%")) >= 99
             and int(s["tick p99 us"]) <= 33000 and int(s["tick overruns"]) <= 3 else "fail"), flush=True)
    time.sleep(0.5)
