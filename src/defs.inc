; defs.inc - shared constants, data layout, wire protocol and imports.
IFDEF LINUX
    .x64
    .model flat
ENDIF
OPTION CASEMAP:NONE

; ---- limits and tuning -------------------------------------------------------
MAX_THREADS     equ 64
MAX_PLAYERS     equ 16777216
MAX_VISIBLE     equ 64              ; entities per snapshot; 536-byte datagram
MAX_GRID        equ 4096            ; grid columns (and rows)
ARRAY_PAD       equ 64              ; spare elements: SIMD may read past the end
HIST_BINS       equ 1048576         ; tick-time histogram: 1 us bins, up to ~1 s
WARMUP_TICKS    equ 16
SPIN_PAUSES     equ 20000           ; spin this long before sleeping in the kernel

; ---- wire protocol (little endian) -------------------------------------------
INPUT_MAGIC     equ 494F4D4Dh       ; "MMOI"
SNAP_MAGIC      equ 53h             ; "S"
SNAP_HEADER     equ 14
SNAP_WIDE_IDS   equ 80h             ; set in the count byte when ids take 3 bytes
INPUT_SIZE      equ 24
; input:    +0 magic  +4 player  +8 seq  +12 i16 dx  +14 i16 dy  +16 u64 client time
; snapshot: +0 u8 magic  +1 u8 count (and SNAP_WIDE_IDS)  +2 u16 tick  +4 u16 ack seq
;           +6 u32 echoed client time (low bits)  +10 u16 own x  +12 u16 own y
;           then count entries of 5 bytes, or 6 with wide ids, least significant first:
;             12 bits dx, 12 bits dy, then the id in the remaining 16 or 24 bits.
;           dx = (field - 2048) * radius / 2047, relative to the receiving player. Own x
;           and y are absolute: x = field * world / 65535.
ADDR_SHIFT      equ 5               ; g_addr: 32 bytes per player, a SOCKADDR_INET
INPUT_RANGE     equ 1000            ; dx/dy are clamped to +-INPUT_RANGE
MAX_SPEED       equ 8               ; world units per second at full input

; ---- tick phases -------------------------------------------------------------
PH_INTEGRATE    equ 1               ; drain inputs, then integrate own slots
PH_SNAPSHOT     equ 2               ; query, encode and send own slots
PH_EXIT         equ 3

; ---- control block: main thread signals, workers wait ------------------------
CTRL_GEN        equ 0
CTRL_PHASE      equ 8
CTRL_DONE       equ 64              ; own cache line: workers hammer this one

; ---- per-thread state; 256 bytes so neighbours never share a cache line ------
WORKER STRUCT
    w_index     dq ?
    w_first     dq ?
    w_last      dq ?
    w_sock      dq ?
    w_txbuf     dq ?
    w_rxbuf     dq ?
    w_rxpkts    dq ?
    w_rxbad     dq ?
    w_txpkts    dq ?
    w_txbytes   dq ?
    w_txfail    dq ?
    w_visible   dq ?
    w_capped    dq ?
    w_rq        dq ?                ; Registered I/O state, see net.asm
    w_cqrx      dq ?
    w_cqtx      dq ?
    w_rxid      dq ?
    w_txid      dq ?
    w_txbase    dq ?
    w_txfree    dq ?
    w_txtop     dq ?
    w_txcur     dq ?
    w_txpending dq ?
    w_results   dq ?
    w_tcommit   dq ?                ; trace build only: commit time this phase
    w_tcommitmax dq ?
    w_profcycles dq ?               ; query timing during profiling ticks
    w_profcount dq ?
    w_pad       db 32 dup(?)
WORKER ENDS

; ---- globals: written during startup, read-only while ticking ----------------
EXTERNDEF g_serve:QWORD
EXTERNDEF g_players:QWORD
EXTERNDEF g_threads:QWORD
EXTERNDEF g_port:QWORD
EXTERNDEF g_hz:QWORD
EXTERNDEF g_gw:QWORD
EXTERNDEF g_stride:QWORD
EXTERNDEF g_ncells:QWORD
EXTERNDEF g_tick:QWORD
EXTERNDEF g_dt:DWORD
EXTERNDEF g_worldmax:DWORD
EXTERNDEF g_r2:DWORD
EXTERNDEF g_inv:DWORD
EXTERNDEF g_quant:DWORD
EXTERNDEF g_relscale:DWORD
EXTERNDEF g_entsize:QWORD
EXTERNDEF g_cpu_level:QWORD
EXTERNDEF g_force_tier:QWORD
EXTERNDEF g_workers:QWORD
EXTERNDEF g_px:QWORD
EXTERNDEF g_py:QWORD
EXTERNDEF g_vx:QWORD
EXTERNDEF g_vy:QWORD
EXTERNDEF g_cell:QWORD
EXTERNDEF g_start:QWORD
EXTERNDEF g_sx:QWORD
EXTERNDEF g_sy:QWORD
EXTERNDEF g_id:QWORD
EXTERNDEF g_seq:QWORD
EXTERNDEF g_echo:QWORD
EXTERNDEF g_addr:QWORD

; ---- our own procedures ------------------------------------------------------
EXTERNDEF start:PROC
EXTERNDEF os_init:PROC
EXTERNDEF os_args:PROC
EXTERNDEF os_write:PROC
EXTERNDEF os_exit:PROC
EXTERNDEF os_alloc:PROC
EXTERNDEF os_freq:PROC
EXTERNDEF os_cpu_count:PROC
EXTERNDEF os_pin:PROC
EXTERNDEF os_spawn:PROC
EXTERNDEF os_wait:PROC
EXTERNDEF os_wake:PROC
EXTERNDEF os_sleep:PROC
EXTERNDEF os_raise_priority:PROC
EXTERNDEF os_code_writable:PROC
EXTERNDEF os_code_executable:PROC
EXTERNDEF os_thread_cycles:PROC
EXTERNDEF os_write_file:PROC
EXTERNDEF input_apply:PROC
EXTERNDEF print_str:PROC
EXTERNDEF print_u64:PROC
EXTERNDEF die:PROC
EXTERNDEF alloc_zeroed:PROC
EXTERNDEF now_qpc:PROC
EXTERNDEF muldiv:PROC
EXTERNDEF rand32:PROC
EXTERNDEF cpu_check:PROC
EXTERNDEF sim_grid_build:PROC
EXTERNDEF integrate_scalar:PROC
EXTERNDEF integrate_avx2:PROC
EXTERNDEF cells_scalar:PROC
EXTERNDEF cells_avx2:PROC
EXTERNDEF query_scalar:PROC
EXTERNDEF query_avx2:PROC
EXTERNDEF query_avx512:PROC
EXTERNDEF site_query:PROC
EXTERNDEF site_integrate:PROC
EXTERNDEF site_cells:PROC
EXTERNDEF tier_init:PROC
EXTERNDEF tier_tick:PROC
EXTERNDEF tier_report:PROC
EXTERNDEF net_startup:PROC
EXTERNDEF net_open:PROC
EXTERNDEF net_drain:PROC
EXTERNDEF net_reclaim:PROC
EXTERNDEF net_flush:PROC
EXTERNDEF net_tx_acquire:PROC
EXTERNDEF net_send:PROC

; ---- Windows imports, used by os_windows.asm and net.asm only ----------------
EXTERNDEF ExitProcess:PROC
EXTERNDEF GetStdHandle:PROC
EXTERNDEF WriteFile:PROC
EXTERNDEF CreateFileA:PROC
EXTERNDEF QueryThreadCycleTime:PROC
EXTERNDEF GetCommandLineA:PROC
EXTERNDEF GetSystemInfo:PROC
EXTERNDEF VirtualAlloc:PROC
EXTERNDEF VirtualProtect:PROC
EXTERNDEF FlushInstructionCache:PROC
EXTERNDEF GetCurrentProcess:PROC
EXTERNDEF SetPriorityClass:PROC
EXTERNDEF QueryPerformanceCounter:PROC
EXTERNDEF QueryPerformanceFrequency:PROC
EXTERNDEF CreateThread:PROC
EXTERNDEF GetCurrentThread:PROC
EXTERNDEF SetThreadAffinityMask:PROC
EXTERNDEF WaitOnAddress:PROC
EXTERNDEF WakeByAddressAll:PROC
EXTERNDEF CreateWaitableTimerExW:PROC
EXTERNDEF SetWaitableTimer:PROC
EXTERNDEF WaitForSingleObject:PROC
EXTERNDEF WSAStartup:PROC
EXTERNDEF WSAIoctl:PROC
EXTERNDEF WSAGetLastError:PROC
EXTERNDEF WSASocketW:PROC
EXTERNDEF closesocket:PROC
EXTERNDEF bind:PROC
EXTERNDEF setsockopt:PROC

; Trace build (ml64 /DTRACE): time every commit. These expand to nothing otherwise.
; Both need rbx = WORKER* and a free qword at [rsp + 40].
TRACE_COMMIT_BEGIN MACRO
    IFDEF TRACE
    call now_qpc
    mov [rsp + 40], rax
    ENDIF
ENDM
TRACE_COMMIT_END MACRO
    LOCAL smaller
    IFDEF TRACE
    call now_qpc
    sub rax, [rsp + 40]
    add [rbx].WORKER.w_tcommit, rax
    cmp rax, [rbx].WORKER.w_tcommitmax
    jbe smaller
    mov [rbx].WORKER.w_tcommitmax, rax
smaller:
    ENDIF
ENDM

; PRINT "text" - write a literal to stdout. Clobbers volatile registers.
PRINT MACRO text:VARARG
    LOCAL lbl
    .const
lbl db text, 0
    .code
    lea rcx, lbl
    call print_str
ENDM

; FAIL "text" - print a message and exit with status 1.
FAIL MACRO text:VARARG
    LOCAL lbl
    .const
lbl db text, 13, 10, 0
    .code
    lea rcx, lbl
    call die
ENDM
