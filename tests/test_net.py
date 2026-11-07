#!/usr/bin/env python3
"""End-to-end test of a running `mmoserver serve`: real UDP, hostile input included.

Starts the server, plays a client by the protocol, throws malformed packets at it,
checks the replies, and checks that the server survived and counted the rejects.

    python tests/test_net.py
"""
import os
import pathlib
import re
import socket
import struct
import subprocess
import sys
import time

EXE = pathlib.Path(__file__).resolve().parent.parent / "build" / ("mmoserver.exe" if os.name == "nt" else "mmoserver")
PORT = 27900
PLAYERS = 64
INPUT_MAGIC = 0x494F4D4D
SNAP_MAGIC = 0x53
WIDE_IDS = 0x80
MAX_VISIBLE = 64
HEADER = struct.Struct("<BBHHIHH")

failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


def packet(player, seq, dx=0, dy=0, stamp=0, magic=INPUT_MAGIC):
    return struct.pack("<IIIhhQ", magic, player, seq, dx, dy, stamp)


def latest(sock):
    """Drain the socket and return the newest snapshot as (header fields, entries)."""
    newest = None
    deadline = time.time() + 0.3
    while time.time() < deadline:
        try:
            newest = sock.recv(2048)
        except (socket.timeout, BlockingIOError):
            if newest:
                break
    if newest is None:
        return None
    fields = HEADER.unpack_from(newest)
    count = fields[1] & ~WIDE_IDS
    width = 6 if fields[1] & WIDE_IDS else 5
    entries = []
    for i in range(count):
        raw = int.from_bytes(newest[HEADER.size + i * width:HEADER.size + (i + 1) * width], "little")
        entries.append((raw & 0xFFF, raw >> 12 & 0xFFF, raw >> 24))
    return fields, entries, len(newest)


server = subprocess.Popen(
    [str(EXE), "serve", str(PLAYERS), "6", "1", "400", "50", "30", str(PORT)],
    stdout=subprocess.PIPE, text=True)
time.sleep(0.3)

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.connect(("127.0.0.1", PORT))
sock.settimeout(0.1)

# A normal client gets a well-formed snapshot that echoes its data.
sock.send(packet(5, 1, stamp=0x1122334455667788))
result = latest(sock)
check(result is not None, "client receives snapshots")
if result is None:
    server.kill()
    sys.exit(1)
(magic, count, tick, ack, echo, own_x, own_y), entries, size = result
check(magic == SNAP_MAGIC, "snapshot magic")
check(ack == 1, "input sequence is acknowledged")
check(echo == 0x55667788, "client timestamp is echoed")
check(not count & WIDE_IDS and size == HEADER.size + count * 5, "datagram size matches its count")
check(0 < count <= MAX_VISIBLE, f"entry count is in range ({count})")
check(any(e == (2048, 2048, 5) for e in entries), "player sees itself at the centre")

# Old sequence numbers are ignored.
sock.send(packet(5, 100, stamp=100))
time.sleep(0.1)
sock.send(packet(5, 50, stamp=50))
result = latest(sock)
check(result[0][3] == 100, "stale input does not rewind the sequence")

# The server enforces top speed, whatever the client asks for.
sock.send(packet(5, 200, dx=32767, dy=32767, stamp=1))
time.sleep(0.2)
first = latest(sock)[0][5]
time.sleep(1.0)
second = latest(sock)[0][5]
moved = abs(second - first) * 400 / 65535
check(0 < moved < 8 * 2.0, f"speed is clamped ({moved:.1f} units moved in ~1 s; limit 8/s)")

# Hostile traffic: every one of these must be counted and ignored, without a crash.
hostile = [
    b"",                                    # empty
    b"x",                                   # too short
    b"\xff" * 23,                           # one byte short
    b"\xff" * 25,                           # one byte long
    b"\x00" * 24,                           # zero magic
    packet(5, 999, magic=0xDEADBEEF),       # wrong magic
    packet(PLAYERS, 999),                   # first slot past the end
    packet(0xFFFFFFFF, 999),                # slot far past the end
    b"\xff" * 5000,                         # larger than the receive buffer
]
for bad in hostile:
    sock.send(bad)
    time.sleep(0.05)

# A valid client still works afterwards.
sock.send(packet(9, 1, stamp=0xABCDEF))
echoes = set()
deadline = time.time() + 0.3
while time.time() < deadline:
    try:
        echoes.add(HEADER.unpack_from(sock.recv(2048))[4])
    except socket.timeout:
        pass
check(0xABCDEF in echoes, "server still processes valid input after hostile traffic")

output, _ = server.communicate(timeout=15)
stats = {k.strip(): int(v) for k, v in re.findall(r"^([^:\n]+?)\s*:\s*(\d+)\s*$", output, re.M)}
check(server.returncode == 0, f"server exits cleanly (status {server.returncode})")
# The empty datagram, and sizes other than 24, are all rejected. Allow the oversized
# one to be counted either way: Windows reports it as an error, not a short read.
check(stats.get("inputs rejected", 0) >= len(hostile) - 1,
      f"hostile packets rejected ({stats.get('inputs rejected')} of {len(hostile)})")
check(stats.get("send failures", 1) == 0, "no send failures")
check(stats.get("snapshots", 0) > 0, "server counted snapshots")

# A world too big for 2-byte ids switches to 3-byte ids, flagged in the header.
server = subprocess.Popen(
    [str(EXE), "serve", "70000", "2", "1", "4000", "50", "30", str(PORT + 1)],
    stdout=subprocess.DEVNULL)
time.sleep(0.3)
wide = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
wide.connect(("127.0.0.1", PORT + 1))
wide.settimeout(0.5)
wide.send(packet(66000, 1))
try:
    data = wide.recv(2048)
    fields = HEADER.unpack_from(data)
    count = fields[1] & ~WIDE_IDS
    ids = [int.from_bytes(data[HEADER.size + i * 6 + 3:HEADER.size + i * 6 + 6], "little")
           for i in range(count)]
    check(bool(fields[1] & WIDE_IDS) and len(data) == HEADER.size + count * 6, "large world uses 6-byte entries")
    check(66000 in ids, "an id above 65,535 survives encoding")
except socket.timeout:
    check(False, "large world answers")
server.wait(timeout=15)

print("\n" + (f"FAILED: {len(failures)}" if failures else "all tests passed"))
sys.exit(1 if failures else 0)
