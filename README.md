# MMO server in x86-64 assembly

An authoritative, fixed-tick MMO server core for Windows and Linux, written entirely in MASM:
about 3,000 lines, an 18 KB executable, and no C runtime. The only code in the process
that isn't ours is the Windows DLLs it calls (kernel32, ws2_32 and the synch API).

**Status: a performance core, not a shippable game server.** It does movement, area of
interest and snapshots over UDP. See [What's missing](#whats-missing).

## Build and run

Needs Visual Studio with the C++ tools (for `ml64` and `link`) and the Windows SDK.
Clang is only needed for the tests and benchmark tools. Any x86-64 CPU should work: the
server detects AVX2 and AVX-512 at startup and otherwise uses its scalar kernels. Only this
AVX-512 machine has run it, with the scalar and AVX2 tiers forced on.

```bash
powershell -ExecutionPolicy Bypass -File build.ps1
```

```bash
build/mmoserver.exe bench 100000 1000 8 3963 50
```

```bash
build/mmoserver.exe serve 10000 60 4 1253 50 30 27000
```

Arguments: `bench <players> <ticks> <threads> <world> <radius>` and
`serve <players> <seconds> <threads> <world> <radius> <hz> <port> [first core] [send every] [tier] [high priority]`.
`bench` accepts the same optional arguments after `<radius>`. `send every` is 1, 2 or 4 ticks
(default 2 for `serve`, 1 for `bench`). `tier` is 0 scalar, 1 AVX2, 2 AVX-512 or 3 choose live
(the default). `high priority` is 0 or 1 (default 1 for `serve`, 0 for `bench`).

| Command | What it does |
| --- | --- |
| `build/test_sim.exe` | Checks the real assembly kernels against brute force |
| `python tests/test_net.py` | End-to-end UDP test, including malformed packets |
| `python bench/run_bench.py` | Assembly vs C, plus player and thread scaling |
| `python bench/run_e2e.py 4` | Real UDP load test with live clients |
| `python bench/diagnose.py` | Traces slow ticks: which worker, and whether it was off the CPU |
| `python bench/trace_tail.py` | Compares slow ticks with typical ticks to show what differs |
| `python bench/run_clean.py` | Full re-measure that repeats runs overlapping other heavy jobs (30+ min) |

### Linux

Needs [UASM v2.56.2](https://github.com/Terraspace/UASM/releases/tag/v2.56.2), GNU ld and gcc. UASM's
master branch doesn't currently compile on Linux, so build the release. The commands are in
[.github/workflows/linux.yml](.github/workflows/linux.yml).

```bash
UASM_BIN=/path/to/uasm sh build_linux.sh
```

```bash
sudo sysctl -w net.core.rmem_max=67108864 net.core.wmem_max=67108864
```

```bash
build/mmoserver serve 5000 60 2 793 50 30 27000
```

Inputs queue in the socket buffer between ticks, and Linux's default limit is small, which is why the
`sysctl` matters. The server warns if its buffer is limited.

The result is a static executable with no libc: only raw system calls. High priority uses `nice -10`,
which an ordinary user usually isn't allowed to set. The report's `high priority` line shows whether
it applied.

**What's been tested on Linux:** every push runs the kernels against brute force on each tier, real UDP
with hostile packets, and short load tests, on a 4-CPU GitHub Actions machine. The simulation produces
exactly the same byte totals as on Windows. Linux networking uses `recvmmsg` and `sendmmsg`, with
`io_uring` and AF_XDP as possible later steps.

**Not yet on Linux:** the trace build, and any meaningful capacity figure. All the performance numbers
below were measured on Windows. FreeBSD and other Unix systems would each need their own OS layer.

## Design

Each tick has three steps. The main thread acts as worker 0.

1. **Integrate (parallel):** each worker drains its own socket and moves its own slots.
2. **Grid build (main thread):** a counting sort puts every entity into a spatial grid.
3. **Snapshot (parallel):** for each slot, find visible entities, encode, and send.

The decisions that make it fast:

- **Structure-of-arrays entities**, processed 8 at a time with AVX2.
- **The grid is rebuilt every tick and copies positions into cell order.** The 3 cells
  in a grid row are adjacent in memory, so a 3x3 neighbour lookup becomes 3 linear scans.
- **Compact, viewer-relative snapshots.** Relative positions come from the same SIMD
  differences as the distance test, and each entry takes 5 or 6 bytes.
- **Registered I/O (RIO) for all network traffic.** Buffers are registered once at
  startup and snapshots are encoded directly into them. Sends and receives are queued in
  user mode and committed in batches of up to 256, and completions are polled.
- **Shared-nothing workers.** Each one owns a slot range, a socket (`port + index`) and
  its RIO queues, with no locks on the hot path. Worker state is padded to separate cache lines, and
  threads are pinned to physical cores.
- **The server is authoritative.** Clients send only a direction: speed is clamped on
  the server. Bad sizes, bad magic, foreign slots and stale sequence numbers are dropped.

| File | Contents |
| --- | --- |
| [src/defs.inc](src/defs.inc) | Constants, wire protocol, shared declarations |
| [src/sim.asm](src/sim.asm) | Hot kernels in scalar, AVX2 and AVX-512 tiers |
| [src/tier.asm](src/tier.asm) | Self-patching code sites and live tier selection |
| [src/os_windows.asm](src/os_windows.asm), [src/os_linux.asm](src/os_linux.asm) | Everything the server needs from each OS, except sockets |
| [src/net.asm](src/net.asm) | Windows networking: Registered I/O |
| [src/net_linux.asm](src/net_linux.asm) | Linux networking: `recvmmsg` and `sendmmsg` |
| [src/input.asm](src/input.asm) | Input validation, shared by both |
| [src/main.asm](src/main.asm) | Startup, threads, tick loop, report |
| [src/util.asm](src/util.asm) | Console, memory, time, CPU check |
| [bench/](bench/), [tools/](tools/), [tests/](tests/) | C and Python test tools; not part of the server |

## Benchmark results

Ryzen 7 9800X3D (8 cores, 16 threads), 31 GB RAM, Windows 11. This is a desktop with
other applications running, not a controlled server. Workload: about 50 entities visible
per player, radius 50, up to 64 entities per snapshot.

### Assembly vs C (one thread, simulation only, median of 7 runs)

The published numbers below aren't like-for-like, so this is the fairest test here: the
same workload, algorithm and core.

| Players | Assembly | C + AVX2 intrinsics | Plain C (`clang -O3`) |
| --- | --- | --- | --- |
| 10,000 | **178** ns/player/tick | 192 | 408 |
| 100,000 | **207** | 216 | 446 |
| 1,000,000 | **250** | 260 | 512 |

Assembly is 2.0 to 2.3x faster than plain C, but only 4 to 7% faster than C with
intrinsics, and repeat runs of the same assembly binary differ by about 4%. **Most of the
gain comes from SIMD and data layout, not from writing assembly by hand.**

### Thread scaling (assembly, simulation only)

| Players | Threads | Tick avg | Tick p99 | Speedup |
| --- | --- | --- | --- | --- |
| 100,000 | 1 | 19.9 ms | 21.8 ms | 1.00 |
| 100,000 | 8 | 2.8 ms | 3.6 ms | 7.08 |
| 1,000,000 | 1 | 241 ms | 261 ms | 1.00 |
| 1,000,000 | 8 | 36 ms | 43 ms | 6.70 |

One million players misses the 33 ms budget for 30 Hz, but fits 20 Hz (50 ms).

A worst-case battle (10,000 players in a 200x200 area, 8 threads) took 0.43 ms p50 and
1.2 ms p99. That is fast because of the cap: almost every snapshot was limited to 64
entities, so players see only part of the battle.

### End to end (real UDP over loopback, 30 Hz, every player a live client)

4 server threads and 4 load-generator threads on separate cores, 10 s per run. Old and
new I/O ran in 3 alternating passes, so both saw similar conditions. The load generator
is the same `sendto`-based C tool for both. Values are medians, with p99 as a range
because it varied so much.

| Players | Tick p50, `sendto` | Tick p50, RIO | Change | Tick p99, RIO (range) | Delivery, RIO (range) |
| --- | --- | --- | --- | --- | --- |
| 5,000 | 7.0 ms | 5.4 ms | -23% | 16-22 ms | 83-100% |
| 10,000 | 14.9 ms | 11.7 ms | -22% | 16-127 ms | 84-100% |
| 15,000 | 23.4 ms | 16.5 ms | -29% | 31-251 ms | 57-100% |
| 20,000 | 28.1 ms | 23.3 ms | -17% | 43-266 ms | 79-99% |

At 30,000 players both are overloaded, but RIO carries more: 1.54 million packets/s and
84% delivery, against 1.28 million and 56% with `sendto` (medians).

- **RIO cut per-tick network cost by about 20-30% and raised peak throughput by about
  20%.** It did not remove the bottleneck.
- **Capacity:** see the player-limit test below, which is newer than this table.
- **These runs may have been competing for CPU, so treat them as provisional.** Occasional
  ticks of 100-250 ms lost many snapshots, with either I/O path. A later trace found workers
  ready to run but off the CPU, while another job held all 16 logical CPUs at about 100%.
  At 15,000 players under that load, slow ticks fell from 87 to 11 across 8 runs each when
  server and client ran at high priority, and median delivery rose from about 98% to 100%.
  A later load monitor logged other heavy jobs at the same time as the two worst runs. It
  isn't known how much of this table was affected.
- **A partial re-measure was stopped early.** It discarded any run overlapping other heavy
  jobs, and finished only 5,000 players on both I/O paths: tick p50 was 7.5 ms with `sendto`
  and 6.3 ms with RIO, about 16% lower. At 5,000 players RIO's p99 was 26 ms (22-97 ms), so
  some slow ticks remained even with those runs discarded. Larger counts are unverified, and
  the simulation tables above were not re-measured.
- **Worker placement:** workers now start on physical core 1 by default. Across 16 runs per
  setting, worker 0 usually spent about 200 ms off the CPU per run, against about 700 ms
  when pinned to logical CPU 0, and most batches had fewer slow ticks. The tables above
  predate this change.
- **Round trip** was 36-46 ms p99 in clean runs. It mostly reflects waiting for the next
  33 ms tick, so RIO doesn't noticeably change it.

### Player-limit test (RIO, workers from core 1)

**Superseded:** this predates staggering and high priority. See "Player limit and slow ticks" below.

3 passes of 10 s runs at 30 Hz, 4 server and 4 load-generator threads, with the load monitor
on. Runs that overlapped another process using over one core are left out of these ranges.
Each row has only 2 or 3 runs, so this is a rough guide. "Overruns" counts ticks of 360 that
missed their deadline.

| Players | Runs | Delivery | Tick p50 | Tick p99 | Overruns | Packets/s |
| --- | --- | --- | --- | --- | --- | --- |
| 10,000 | 2 | 97-100% | 11-12 ms | 31-61 ms | 9-10 | 590,000-600,000 |
| 15,000 | 2 | 98-99% | 19 ms | 30-52 ms | 7-19 | 890,000-900,000 |
| 20,000 | 2 | 84-98% | 25-26 ms | 53-129 ms | 31-75 | 1.10-1.19 million |
| 25,000 | 2 | 80-98% | 31-33 ms | 42-112 ms | 79-167 | 1.32-1.48 million |

- **Practical limit on this desktop: about 15,000 players,** with occasional slow ticks and
  some lost snapshots, so not a guaranteed figure.
- **20,000 usually keeps up but is unreliable:** its p99 always missed the 33 ms budget.
- **25,000 is saturated:** the median tick is at the budget and many ticks miss it.
- **Unexplained slow ticks remain,** including some runs with no heavy process logged. The
  monitor samples every 5 s and can miss short jobs, so the cause isn't settled.

### Compact snapshots

Entries are now 5 bytes instead of 8 (6 in worlds above 65,536 entities), with positions
relative to the receiving player, and the header is 14 bytes instead of 24. No per-client
state is kept, so a lost packet doesn't affect later ones. Precision at radius 50 is about
0.024 units. Old and new ran on the same machine; runs overlapping logged outside load are
excluded, which left only 1 or 2 runs per row and none for the new format at 15,000 players.

| Measure | Old | New | Change |
| --- | --- | --- | --- |
| Average payload, up to 65,536 entities | 418 bytes | 260 bytes | -38% |
| Average payload, above 65,536 entities | 427 bytes | 316 bytes | -26% |
| Tick p50 at 10,000 players | 10-12 ms | 12 ms | no clear change |
| Tick p50 at 20,000 players | 22 ms | 22 ms | no clear change |
| Simulation only, 100,000 players | 191-199 ns/player/tick | 193 ns/player/tick | no clear change |

- **Less bandwidth, not more players on loopback.** The tick cost is almost unchanged, because
  the network stack's cost follows packets far more than bytes.
- **Calculated, not measured:** including UDP, IP and Ethernet overhead, a 1 Gbps card's limit
  at 30 Hz rises from about 8,600 players to about 12,800. Measuring it needs a second machine.

The simulation tables above predate this format. In a single check at 100,000 players, C with
AVX2 intrinsics took 192 ns and plain C took 411 ns, so hand-written assembly showed no clear
lead over intrinsics on the new format.

### Staggered snapshots

The simulation stays at 30 Hz, but each player now gets a snapshot every other tick (15 per
second), with players spread evenly across ticks. Two alternating passes, 4 server threads, no
outside load logged:

| Players | Sent every | Delivery | Tick p50 | Tick p99 | Overruns of 360 |
| --- | --- | --- | --- | --- | --- |
| 15,000 | tick | 98-100% | 17-18 ms | 45-48 ms | 6-17 |
| 15,000 | 2 ticks | 100% | 9 ms | 22-24 ms | 1-3 |
| 20,000 | tick | 99% | 24 ms | 37-38 ms | 7-19 |
| 20,000 | 2 ticks | 95-100% | 11-13 ms | 25-85 ms | 4-16 |
| 30,000 | tick | 90% | 35 ms | 47-54 ms | 254-266 |
| 30,000 | 2 ticks | 98-100% | 18-19 ms | 29-37 ms | 3-12 |

- **Staggering halves the median tick.** These runs predate high priority: see the limit test
  below for current figures.
- **Calculated, not measured:** a 1 Gbps card's snapshot limit at 15 per second is about 25,600
  players.
- **Trade-off:** clients get fewer updates and have to smooth between them. No real client exists
  yet, and round-trip time here includes waiting for the player's snapshot tick.

### Player limit and slow ticks

A run passes only if the load generator sent at least 99% of its inputs, delivery is at least
99%, tick p99 is within the 33 ms budget, and at most 3 of 360 ticks are late. 4 server and 4
load-generator threads share 8 cores, over loopback, simulating movement only. Each row is 2
to 4 runs, with the server at high priority (now the default for `serve`).

| Players | Inputs per second | Runs passing | Tick p50 | Tick p99 | Late ticks | Delivery |
| --- | --- | --- | --- | --- | --- | --- |
| 20,000 | 30 | 4 of 4 | 12-13 ms | 18-19 ms | 0 | 100% |
| **25,000** | 30 | **2 of 2** | 15-16 ms | 20-23 ms | 0 | 100% |
| 30,000 | 30 | 0 of 2: generator sent 74-96% of inputs | 19-22 ms | 24-30 ms | 0-2 | 100% |
| **30,000** | 15 | **2 of 2** | 18-20 ms | 28-30 ms | 0-1 | 100% |
| 35,000 | 15 | 0 of 2 | 24-26 ms | 34-35 ms | 4-6 | 100% |
| 40,000 | 15 | 0 of 2 (95-97% of inputs) | 29 ms | 42-44 ms | 16-20 | 99% |
| 50,000 | 15 | 0 of 2 (80-94% of inputs) | 34 ms | 43-44 ms | 198-237 | 93-94% |

- **Strict limit: 25,000 players at 30 inputs per second, or 30,000 at 15.** The earlier strict
  figure at normal priority was about 15,000.
- **30,000 at 30 inputs per second is unproven:** the server looked healthy, but the load generator
  fell short, and in one run another job was competing for the CPU.
- **Other jobs overlapped from the second 30-input pass onward,** including both 15-input passes.
  So the 35,000 and above results may understate the server. The 30,000 runs at 15 inputs passed
  despite this.
- **Saturation is near 45,000-50,000,** where the median tick reaches the 33 ms budget.

**Why ticks were slow.** A per-tick trace at 20,000 players, compared with typical ticks, found two
patterns, neither of them too much work:

1. A worker started a phase late, by up to about 25 ms, while its work took the usual time.
2. A worker, usually worker 0, spent about 15-27 ms off the CPU inside one kernel commit.

High priority removed both. In alternating runs at 20,000 players:

| Setting | Ticks over 33 ms | Ticks over 25 ms | Worst tick | Late starts over 5 ms | Off-CPU over 5 ms |
| --- | --- | --- | --- | --- | --- |
| Default | 3-5 | 10-27 | 40-61 ms | 8-38 | 9-17 |
| Workers always spin | 0-1 | 7 | 33-35 ms | 0 | 7-11 |
| High priority | 0 | 0 | 19-20 ms | 0 | 0 |
| Both | 0 | 0 | 19-21 ms | 0 | 0 |

The always-spin option added nothing to high priority and was removed. Those runs raised the load
generator's priority too, but a later check with only the server raised also passed, 2 of 2, while
normal priority failed 2 of 2. The likely mechanism is pinned threads losing their core to
normal-priority threads and being unable to move. That fits the data but wasn't observed directly.

**Trade-off:** at high priority the server can make other programs on those cores less responsive.
On a shared desktop, pass `0` for the high priority argument.

### Live code selection

The server patches its own `jmp` instructions. Startup points each hot kernel at the best tier
the CPU supports. Every 512 ticks, a timing wrapper is patched in for one tick per tier, then the
query site is patched straight to the winner, so timing costs nothing in between. Patches happen
only while workers are idle.

Simulation only, 100,000 players, 1 thread, on a loaded machine, so treat these as approximate:

| World | Visible | Scalar | AVX2 | AVX-512 | Live choice |
| --- | --- | --- | --- | --- | --- |
| Sparse | 6 | 158 ns | 50 ns | 50 ns | AVX2 |
| Normal | 50 | 449 ns | 191 ns | 164 ns | AVX-512 |
| Dense | 67 (capped) | 995 ns | 340 ns | 243 ns | AVX-512 |
| Battle | 66 (capped) | 2,362 ns | 554 ns | 410 ns | AVX-512 |

- **Results are unaffected:** AVX2, AVX-512 and live patching (23 patches) produced identical
  byte totals over 5,000 ticks. That checks totals, not each packet's contents.
- **AVX-512 saves about 14-29% of simulation time** in the three denser worlds, and made no
  difference in the sparse one.
- **It hardly moves the player limit,** since the simulation is a small part of a networked tick,
  and the kernel's network code can't be patched by the server.
- **Self-patching itself adds little:** a function pointer could select tiers too. Its real
  benefit is that profiling costs nothing between samples.
- Each tier is timed on a single tick, so a noisy tick could briefly pick a worse tier. Choices
  are rechecked every 512 ticks.

Removing incremental linking also took an extra `jmp` off every call. Its effect wasn't measured
separately.

### The real bottleneck is still the network stack

At 10,000 players a tick costs about 4.7 us of CPU per player with RIO (6 us before), of
which the simulation is about 0.2 us. **Roughly 95% of the time is still in the network
path.** RIO removes the per-packet syscall, but on loopback the sending thread still runs
the Windows UDP stack for each packet, including delivery to the receiver. A real network
card may behave quite differently, and that hasn't been tested.

## Against published numbers

**None of these is a like-for-like comparison.** They differ in hardware, game logic and
what is measured, so treat this as context rather than a scoreboard.

| Reference | Published | This server | Fair comparison? |
| --- | --- | --- | --- |
| [Altruist](https://altruist-docs.vercel.app/docs/deployment/benchmarks) (.NET framework) | ~10 us/player, ~3,300 players estimated on one thread at 30 Hz | ~0.2 us/player; 100,000 players in 21.8 ms p99 on one thread | Closest, but weak: Altruist's hardware is unstated, its CCU is an estimate, and neither figure includes sockets |
| [EVE: Aether Wars](https://www.ccpgames.com/news/2019/eve-aether-wars-successfully-achieves-groundbreaking-14-000-ship-battle) (Hadean) | 14,274 ships on grid, many of them bots | 25,000 live UDP clients on loopback under a strict test (30 inputs/s), saturating near 50,000; movement only | No: it had real game logic and real internet players |
| [PlanetSide 2](https://www.guinnessworldrecords.com/news/2015/01/planetside-2-gamers-aiming-for-fps-battle-world-record-this-weekend-370414) | 1,158 players in one battle | Not tested with real players | No: a full game with real players |
| [SpacetimeDB](https://spacetimedb.com/blog/benchmarking) | 100,000-300,000 transactions/s, [disputed](https://dev.to/kevburnsjr/spacetimedb-vs-convex-performance-analysis-review-52ak) | Not measured | No: database transactions, a different workload |
| [Windows RIO, 2012](https://serverframework.com/asynchronousevents/2012/07/windows-8-registered-io-performance---finally-using-a-full-10-gigabit-link.html) | ~970,000 datagrams/s received, over real 10 GbE | ~1.5 million packets/s in and out, over loopback | No: different hardware and 14 years apart, and loopback isn't a real NIC |

**What can fairly be claimed:** the simulation core is very fast, and beats plain C by
about 2x on the same workload. **What can't:** that this server beats any real MMO. Those
carry combat, AI, persistence and real networks, and this has none of them yet.

## Kernel driver (in progress)

[driver/](driver/) holds an assembly kernel driver. The goal is to pass the server's UDP
packets through memory shared directly with the network card path, skipping the Windows
network stack.

**Milestone 1 is only the foundation:** the driver creates `\\.\MmoNet`, answers a ping
request and unloads. It has no network code, makes the server no faster, and **has never been
loaded by a real Windows kernel.** What's been checked without one:

- `build/test_driver_image.exe` maps the finished `mmonet.sys` in user mode, applying its
  relocations and imports, then runs it against a fake kernel.
- `tests/check_offsets.c` checks its kernel offsets against the mingw-w64 driver headers at
  build time. Those aren't Microsoft's own headers.
- Its 5 imported functions were confirmed as exports of the real `ntoskrnl.exe` on one PC.

Real signature checks, kernel memory rules, I/O Manager behaviour and any actual packet
handling can only be tested on a real kernel.

Only load it in a test VM: a bug crashes the whole machine, and it needs test signing, which
`driver/vm_setup.ps1` turns on and which refuses to run outside a VM. Copy `mmonet.sys`,
`drvtest.exe` and `vm_setup.ps1` from `build/driver/` to one folder in the VM, turn Secure
Boot off in the VM's settings, then run these from an Administrator PowerShell in the VM:

```powershell
.\vm_setup.ps1 enable
```

Reboot the VM, then:

```powershell
.\vm_setup.ps1 install
```

```powershell
.\drvtest.exe
```

```powershell
.\vm_setup.ps1 remove
```

Before adding shared memory, the device must be restricted to administrators: any local
user can currently open it, which is harmless only while it just answers a ping.

## What's missing

- **Security: no authentication or encryption.** Anyone who can reach the port can control
  any slot by sending its number. The server binds to 127.0.0.1 for this reason; don't
  expose it to a network until this is fixed.
- **Game logic:** no combat, AI, collision, inventory or persistence.
- **Sessions:** no login, and a client's slot stays claimed after it disconnects.
- **Fair capped snapshots:** when capped, entities in lower-numbered cells win rather than
  the nearest, so dense battles show a biased subset. Nor are snapshots delta-compressed.
- **Reliability:** no retransmission or ordering for events that must arrive.
- **Real network testing:** loopback only. Results on a real NIC will differ.
- **Remaining tick stalls:** high priority removed the slow ticks in tests so far, but an earlier
  1 s tick was never explained, and these are short runs on a desktop.
- **Real network testing on Linux:** so far it has only run over loopback.
- **Single-threaded grid build:** only 2.5 ms of a 36 ms tick at 1M players, so not urgent.

## License

[MIT](LICENSE)
