; main.asm - entry point, setup, worker threads, tick loop and the final report.
;
; A tick has three steps. Workers run the parallel ones; the main thread is worker 0.
;   1. PH_INTEGRATE (parallel)  drain inputs, integrate own slots
;   2. sim_grid_build (main)    counting-sort all entities into the grid
;   3. PH_SNAPSHOT  (parallel)  for each own slot: query, encode, send
include defs.inc

.data
g_serve     dq 0
g_players   dq 0
g_threads   dq 0
g_port      dq 0
g_hz        dq 0
g_gw        dq 0
g_stride    dq 0
g_ncells    dq 0
g_tick      dq 0
g_dt        dd 0
g_worldmax  dd 0
g_r2        dd 0
g_inv       dd 0
g_quant     dd 0
g_relscale  dd 0
g_entsize   dq 0
g_px        dq 0
g_py        dq 0
g_vx        dq 0
g_vy        dq 0
g_cell      dq 0
g_start     dq 0
g_sx        dq 0
g_sy        dq 0
g_id        dq 0
g_seq       dq 0
g_echo      dq 0
g_addr      dq 0

cmd_cursor  dq 0
arg_count   dq 0                        ; bench: ticks; serve: seconds
arg_world   dq 0
arg_radius  dq 0
g_workers   dq 0
ctrl        dq 0
hist        dq 0
freq        dq 0
logical_cpus dq 0
first_core  dq 0                        ; physical core that worker 0 is pinned to
send_mask   dq 0                        ; send a player's snapshot when (slot + tick) & this = 0
high_priority dq 0
g_cpu_level dq 0
g_force_tier dq 3
target_ticks dq 0
ticks_run   dq 0
overruns    dq 0
total_integrate dq 0
total_grid  dq 0
total_snap  dq 0
total_tick  dq 0
max_tick_us dq 0

.code

; ---- command line ------------------------------------------------------------

usage PROC                              ; reached by jmp: stack depth unknown
    and rsp, -16
    sub rsp, 32
    FAIL "usage: mmoserver bench <players> <ticks>   <threads> <world> <radius>",13,10,"       mmoserver serve <players> <seconds> <threads> <world> <radius> <hz> <port> [first core] [send every 1/2/4] [tier 0-3] [high priority 0/1]"
usage ENDP

; next_int(rcx = default) -> rax: the next number on the command line, or the
; default if there are no arguments left. Anything else is a usage error.
next_int PROC
    mov r8, cmd_cursor
@@: cmp byte ptr [r8], ' '
    jne @F
    inc r8
    jmp @B
@@: cmp byte ptr [r8], 0
    jne @F
    mov rax, rcx
    mov cmd_cursor, r8
    ret
@@: xor eax, eax
digit:
    movzx edx, byte ptr [r8]
    sub edx, '0'
    cmp edx, 9
    ja stop
    imul rax, rax, 10
    add rax, rdx
    mov rdx, 1000000000000
    cmp rax, rdx
    ja usage
    inc r8
    jmp digit
stop:
    movzx edx, byte ptr [r8]
    test edx, edx
    jz @F
    cmp edx, ' '
    jne usage
@@: mov cmd_cursor, r8
    ret
next_int ENDP

parse_args PROC FRAME
    sub rsp, 40
    .allocstack 40
    .endprolog
    call GetCommandLineA
    mov r8, rax
    ; skip argv[0], which may be quoted
    cmp byte ptr [r8], '"'
    jne plain
    inc r8
quoted:
    mov al, [r8]
    test al, al
    jz usage
    inc r8
    cmp al, '"'
    jne quoted
    jmp mode
plain:
    mov al, [r8]
    test al, al
    jz usage
    cmp al, ' '
    je mode
    inc r8
    jmp plain
mode:
    cmp byte ptr [r8], ' '
    jne @F
    inc r8
    jmp mode
@@: mov al, [r8]
    cmp al, 'b'
    je known
    cmp al, 's'
    jne usage
    mov g_serve, 1
known:
    inc r8
    cmp byte ptr [r8], 0
    je @F
    cmp byte ptr [r8], ' '
    jne known
@@: mov cmd_cursor, r8

    mov ecx, 10000
    call next_int
    mov g_players, rax
    mov ecx, 1000
    call next_int
    mov arg_count, rax
    mov ecx, 1
    call next_int
    mov g_threads, rax
    mov ecx, 1253                       ; 10k players, 50 r: about 50 visible each
    call next_int
    mov arg_world, rax
    mov ecx, 50
    call next_int
    mov arg_radius, rax
    mov ecx, 30
    call next_int
    mov g_hz, rax
    mov ecx, 27000
    call next_int
    mov g_port, rax
    mov ecx, 1                          ; default: stay off logical CPU 0, where worker 0
    call next_int                       ; measurably lost more time off-CPU
    mov first_core, rax
    mov ecx, 1                          ; bench: every tick, for comparable timings
    cmp g_serve, 0
    je @F
    mov ecx, 2                          ; serve: every other tick
@@: call next_int
    mov send_mask, rax
    mov ecx, 3                          ; 0 scalar, 1 AVX2, 2 AVX-512, 3 choose live
    call next_int
    mov g_force_tier, rax
    cmp rax, 3
    ja usage
    mov rcx, g_serve                    ; serve: high priority; bench: normal
    call next_int
    cmp rax, 1
    ja usage
    mov high_priority, rax

    ; validate
    mov rax, send_mask
    cmp rax, 1
    je every_ok
    cmp rax, 2
    je every_ok
    cmp rax, 4
    jne usage
every_ok:
    dec rax
    mov send_mask, rax
    mov rax, g_players
    test rax, rax
    jz usage
    cmp rax, MAX_PLAYERS
    ja usage
    add rax, 7                          ; SIMD kernels work on whole blocks of 8
    and rax, -8
    mov g_players, rax
    cmp arg_count, 0
    je usage
    mov rax, g_threads
    test rax, rax
    jz usage
    cmp rax, MAX_THREADS
    ja usage
    mov rax, arg_radius
    test rax, rax
    jz usage
    cmp rax, arg_world
    ja usage
    mov rax, g_hz
    test rax, rax
    jz usage
    cmp rax, 1000
    ja usage
    mov rax, g_port
    test rax, rax
    jz usage
    add rax, g_threads
    cmp rax, 65535
    ja usage
    add rsp, 40
    ret
parse_args ENDP

; ---- setup -------------------------------------------------------------------

; alloc_elems(rcx = element count, rdx = element size) -> rax
alloc_elems PROC FRAME
    sub rsp, 40
    .allocstack 40
    .endprolog
    add rcx, ARRAY_PAD
    imul rcx, rdx
    call alloc_zeroed
    add rsp, 40
    ret
alloc_elems ENDP

ALLOC_ARRAY MACRO target, count, size
    mov rcx, count
    mov edx, size
    call alloc_elems
    mov target, rax
ENDM

; rand_float() -> xmm0 = uniform in [0, 1)
rand_float PROC FRAME
    sub rsp, 40
    .allocstack 40
    .endprolog
    call rand32
    cvtsi2ss xmm0, rax                  ; rax is zero-extended, so never negative
    mov eax, 2F800000h                  ; 2^-32
    movd xmm1, eax
    mulss xmm0, xmm1
    add rsp, 40
    ret
rand_float ENDP

WORLD_F equ 96                          ; stack slots in setup
SPEED_F equ 100

setup PROC FRAME
    push rbx
    .pushreg rbx
    push rsi
    .pushreg rsi
    push rdi
    .pushreg rdi
    sub rsp, 112
    .allocstack 112
    .endprolog

    lea rcx, [rsp + 32]
    call GetSystemInfo
    mov eax, dword ptr [rsp + 32 + 32]  ; SYSTEM_INFO.dwNumberOfProcessors
    mov logical_cpus, rax

    lea rcx, freq
    call QueryPerformanceFrequency

    ; derived simulation constants
    mov rax, g_hz
    cvtsi2ss xmm1, rax
    mov eax, 3F800000h                  ; 1.0
    movd xmm0, eax
    divss xmm0, xmm1
    movss g_dt, xmm0

    cvtsi2ss xmm0, arg_world
    movss dword ptr [rsp + WORLD_F], xmm0
    movd eax, xmm0
    dec eax                             ; largest float below the world size
    mov g_worldmax, eax

    cvtsi2ss xmm0, arg_radius
    mulss xmm0, xmm0
    movss g_r2, xmm0

    ; Cells are at least one radius wide, so a 3x3 lookup always covers the AOI.
    mov rax, arg_world
    xor edx, edx
    div arg_radius
    mov ecx, MAX_GRID
    cmp rax, rcx
    cmova rax, rcx
    mov g_gw, rax
    cvtsi2ss xmm0, rax
    divss xmm0, dword ptr [rsp + WORLD_F]
    movss g_inv, xmm0
    lea rcx, [rax + 2]
    mov g_stride, rcx
    imul rcx, rcx
    mov g_ncells, rcx

    mov eax, 65535
    cvtsi2ss xmm0, eax
    divss xmm0, dword ptr [rsp + WORLD_F]
    movss g_quant, xmm0

    ; Relative positions: +-radius maps onto 12 bits.
    mov eax, 2047
    cvtsi2ss xmm0, eax
    cvtsi2ss xmm1, arg_radius
    divss xmm0, xmm1
    movss g_relscale, xmm0

    ; Ids fit in 2 bytes in any world of up to 65,536 entities.
    mov eax, 5
    mov ecx, 6
    cmp g_players, 65536
    cmova rax, rcx
    mov g_entsize, rax

    ; storage
    mov rbx, g_players
    ALLOC_ARRAY g_px, rbx, 4
    ALLOC_ARRAY g_py, rbx, 4
    ALLOC_ARRAY g_vx, rbx, 4
    ALLOC_ARRAY g_vy, rbx, 4
    ALLOC_ARRAY g_cell, rbx, 4
    ALLOC_ARRAY g_sx, rbx, 4
    ALLOC_ARRAY g_sy, rbx, 4
    ALLOC_ARRAY g_id, rbx, 4
    ALLOC_ARRAY g_seq, rbx, 4
    ALLOC_ARRAY g_echo, rbx, 8
    ALLOC_ARRAY g_addr, rbx, 32
    mov rcx, g_ncells
    add rcx, 3
    mov edx, 4
    call alloc_elems
    mov g_start, rax
    mov ecx, HIST_BINS
    mov edx, 4
    call alloc_elems
    mov hist, rax
    mov ecx, 4096
    call alloc_zeroed
    mov ctrl, rax

    ; spawn entities at random with random velocities. Slots no client has claimed
    ; simply keep wandering: they are the world's NPCs.
    mov eax, MAX_SPEED
    cvtsi2ss xmm0, eax
    movss dword ptr [rsp + SPEED_F], xmm0
    xor esi, esi
spawn:
    call rand_float
    mulss xmm0, dword ptr [rsp + WORLD_F]
    mov rax, g_px
    movss dword ptr [rax + rsi*4], xmm0
    call rand_float
    mulss xmm0, dword ptr [rsp + WORLD_F]
    mov rax, g_py
    movss dword ptr [rax + rsi*4], xmm0
    call rand_float
    addss xmm0, xmm0                    ; [0, 2) * speed - speed = [-speed, speed)
    mulss xmm0, dword ptr [rsp + SPEED_F]
    subss xmm0, dword ptr [rsp + SPEED_F]
    mov rax, g_vx
    movss dword ptr [rax + rsi*4], xmm0
    call rand_float
    addss xmm0, xmm0
    mulss xmm0, dword ptr [rsp + SPEED_F]
    subss xmm0, dword ptr [rsp + SPEED_F]
    mov rax, g_vy
    movss dword ptr [rax + rsi*4], xmm0
    inc rsi
    cmp rsi, rbx
    jb spawn

    ; Divide slots between workers. Ranges stay multiples of 8.
    mov rax, g_threads
    imul rax, SIZEOF WORKER
    mov rcx, rax
    call alloc_zeroed
    mov g_workers, rax
    mov rax, rbx
    add rax, g_threads
    dec rax
    xor edx, edx
    div g_threads
    add rax, 7
    and rax, -8
    mov rdi, rax                        ; slots per worker
    mov rbx, g_workers
    xor esi, esi
divide:
    mov [rbx].WORKER.w_index, rsi
    mov rax, rsi
    imul rax, rdi
    mov rcx, g_players
    cmp rax, rcx
    cmova rax, rcx
    mov [rbx].WORKER.w_first, rax
    add rax, rdi
    cmp rax, rcx
    cmova rax, rcx
    mov [rbx].WORKER.w_last, rax
    mov ecx, 65536
    call alloc_zeroed
    mov [rbx].WORKER.w_txbuf, rax
    add rbx, SIZEOF WORKER
    inc rsi
    cmp rsi, g_threads
    jb divide

    cmp g_serve, 0
    je done
    call net_startup
    mov rbx, g_workers
    xor esi, esi
sockets:
    mov rcx, rbx
    call net_open
    add rbx, SIZEOF WORKER
    inc rsi
    cmp rsi, g_threads
    jb sockets
done:
    add rsp, 112
    pop rdi
    pop rsi
    pop rbx
    ret
setup ENDP

; ---- phases ------------------------------------------------------------------

; worker_snapshot(rcx = WORKER*) - build one snapshot per owned slot.
; Benchmark mode does all the work except the network I/O, encoding into a scratch
; buffer. Serving encodes directly into registered memory, so nothing is copied.
worker_snapshot PROC FRAME
    push rbx
    .pushreg rbx
    push rsi
    .pushreg rsi
    push rdi
    .pushreg rdi
    sub rsp, 32
    .allocstack 32
    .endprolog
    mov rbx, rcx
    mov rsi, [rbx].WORKER.w_first
    mov rdi, [rbx].WORKER.w_txbuf
    cmp g_serve, 0
    je slot
    mov rcx, rbx                        ; last tick's sends have finished by now
    call net_reclaim
slot:
    cmp rsi, [rbx].WORKER.w_last
    jae done
    mov rax, rsi                        ; stagger: spreads players evenly across ticks
    add rax, g_tick
    test rax, send_mask
    jnz next
    cmp g_serve, 0
    je build
    mov rax, g_addr                     ; unclaimed slots have no address yet
    mov rcx, rsi
    shl rcx, ADDR_SHIFT
    cmp word ptr [rax + rcx], 0
    je next
    mov rcx, rbx
    call net_tx_acquire
    test rax, rax
    jz next                             ; no free buffer: this snapshot is dropped
    mov rdi, rax
build:
    mov rcx, rsi
    lea rdx, [rdi + SNAP_HEADER]
    mov r8, rbx                         ; only the profiling wrapper reads this
    call site_query
    add [rbx].WORKER.w_visible, rax
    cmp rax, MAX_VISIBLE
    jbe fits
    inc [rbx].WORKER.w_capped
    mov eax, MAX_VISIBLE
fits:
    mov r8, rax
    imul r8, g_entsize
    add r8, SNAP_HEADER                 ; datagram bytes
    mov byte ptr [rdi], SNAP_MAGIC
    cmp g_entsize, 6
    jne @F
    or eax, SNAP_WIDE_IDS
@@: mov byte ptr [rdi + 1], al
    mov rcx, g_tick
    mov word ptr [rdi + 2], cx
    mov rcx, g_seq
    mov ecx, dword ptr [rcx + rsi*4]
    mov word ptr [rdi + 4], cx
    mov rcx, g_echo
    mov rcx, [rcx + rsi*8]
    mov dword ptr [rdi + 6], ecx
    mov rcx, g_px
    movss xmm0, dword ptr [rcx + rsi*4]
    mulss xmm0, g_quant
    cvttss2si eax, xmm0
    mov word ptr [rdi + 10], ax
    mov rcx, g_py
    movss xmm0, dword ptr [rcx + rsi*4]
    mulss xmm0, g_quant
    cvttss2si eax, xmm0
    mov word ptr [rdi + 12], ax
    cmp g_serve, 0
    jne transmit
    inc [rbx].WORKER.w_txpkts
    add [rbx].WORKER.w_txbytes, r8
    jmp next
transmit:
    mov rcx, rbx
    mov rdx, rsi
    call net_send
next:
    inc rsi
    jmp slot
done:
    cmp g_serve, 0
    je @F
    mov rcx, rbx
    call net_flush
@@: add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
worker_snapshot ENDP

; worker_phase(rcx = WORKER*, rdx = phase)
worker_phase PROC FRAME
    push rbx
    .pushreg rbx
    sub rsp, 32
    .allocstack 32
    .endprolog
    mov rbx, rcx
    cmp rdx, PH_SNAPSHOT
    je snapshot
    cmp g_serve, 0
    je integrate
    call net_drain
integrate:
    mov rcx, [rbx].WORKER.w_first
    mov rdx, [rbx].WORKER.w_last
    call site_integrate
    jmp done
snapshot:
    mov rcx, rbx
    call worker_snapshot
done:
    add rsp, 32
    pop rbx
    ret
worker_phase ENDP

IFNDEF TRACE
worker_run EQU worker_phase
ELSE
; ---- trace build only: one record per tick per worker, written to trace.bin ----
; Record: 2 groups (integrate, snapshot) of 6 qwords each:
;   start QPC, end QPC, thread cycles used, packets handled, commit total, commit max
TRACE_TICKS     equ 65536
TRACE_RECORD    equ 96
TRACE_HEADER    equ 64

.data
trace_buf       dq 0
.code

; thread_cycles() -> rax = CPU cycles this thread has consumed
thread_cycles PROC FRAME
    sub rsp, 56
    .allocstack 56
    .endprolog
    call GetCurrentThread
    mov rcx, rax
    lea rdx, [rsp + 40]
    call QueryThreadCycleTime
    mov rax, [rsp + 40]
    add rsp, 56
    ret
thread_cycles ENDP

worker_run PROC FRAME
    push rbx
    .pushreg rbx
    push rsi
    .pushreg rsi
    push rdi
    .pushreg rdi
    push r12
    .pushreg r12
    push r13
    .pushreg r13
    sub rsp, 32
    .allocstack 32
    .endprolog
    mov rbx, rcx
    mov rsi, rdx
    mov rax, g_tick
    cmp rax, TRACE_TICKS
    jae untraced
    imul rax, g_threads
    add rax, [rbx].WORKER.w_index
    imul rax, rax, TRACE_RECORD
    add rax, trace_buf
    lea rdi, [rax + TRACE_HEADER]
    cmp rsi, PH_SNAPSHOT
    jne @F
    add rdi, 48
@@: xor eax, eax
    mov [rbx].WORKER.w_tcommit, rax
    mov [rbx].WORKER.w_tcommitmax, rax
    mov r13, [rbx].WORKER.w_rxpkts
    cmp rsi, PH_SNAPSHOT
    cmove r13, [rbx].WORKER.w_txpkts
    call thread_cycles
    mov r12, rax
    call now_qpc
    mov [rdi], rax

    mov rcx, rbx
    mov rdx, rsi
    call worker_phase

    call now_qpc
    mov [rdi + 8], rax
    call thread_cycles
    sub rax, r12
    mov [rdi + 16], rax
    mov rax, [rbx].WORKER.w_rxpkts
    cmp rsi, PH_SNAPSHOT
    cmove rax, [rbx].WORKER.w_txpkts
    sub rax, r13
    mov [rdi + 24], rax
    mov rax, [rbx].WORKER.w_tcommit
    mov [rdi + 32], rax
    mov rax, [rbx].WORKER.w_tcommitmax
    mov [rdi + 40], rax
    jmp done
untraced:
    mov rcx, rbx
    mov rdx, rsi
    call worker_phase
done:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
worker_run ENDP

trace_alloc PROC FRAME
    sub rsp, 40
    .allocstack 40
    .endprolog
    mov rcx, g_threads
    imul rcx, rcx, TRACE_RECORD * TRACE_TICKS
    add rcx, TRACE_HEADER
    call alloc_zeroed
    mov trace_buf, rax
    add rsp, 40
    ret
trace_alloc ENDP

; Header: threads, ticks recorded, QPC frequency, record bytes
trace_dump PROC FRAME
    push rbx
    .pushreg rbx
    push rsi
    .pushreg rsi
    sub rsp, 72
    .allocstack 72
    .endprolog
    mov rax, trace_buf
    mov rcx, g_threads
    mov [rax], rcx
    mov rcx, g_tick
    mov edx, TRACE_TICKS
    cmp rcx, rdx
    cmova rcx, rdx
    mov [rax + 8], rcx
    mov rdx, freq
    mov [rax + 16], rdx
    mov qword ptr [rax + 24], TRACE_RECORD
    imul rcx, g_threads
    imul rcx, rcx, TRACE_RECORD
    lea rsi, [rcx + TRACE_HEADER]
    .const
trace_name db "trace.bin", 0
    .code
    lea rcx, trace_name
    mov edx, 40000000h                  ; GENERIC_WRITE
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 2         ; CREATE_ALWAYS
    mov qword ptr [rsp + 40], 80h       ; FILE_ATTRIBUTE_NORMAL
    mov qword ptr [rsp + 48], 0
    call CreateFileA
    mov rbx, rax
    mov rcx, rax
    mov rdx, trace_buf
    mov r8, rsi
    lea r9, [rsp + 56]
    mov qword ptr [rsp + 32], 0
    call WriteFile
    add rsp, 72
    pop rsi
    pop rbx
    ret
trace_dump ENDP
ENDIF

; pin_current(rcx = worker index) - one worker per physical core (assumes 2-way SMT)
pin_current PROC FRAME
    push rbx
    .pushreg rbx
    sub rsp, 32
    .allocstack 32
    .endprolog
    add rcx, first_core
    lea rax, [rcx + rcx]
    xor edx, edx
    div logical_cpus
    mov eax, 1
    mov ecx, edx
    shl rax, cl
    mov rbx, rax
    call GetCurrentThread
    mov rcx, rax
    mov rdx, rbx
    call SetThreadAffinityMask
    add rsp, 32
    pop rbx
    ret
pin_current ENDP

; Thread body of workers 1..n: wait for a new generation, run its phase, report.
worker_main PROC FRAME
    push rbx
    .pushreg rbx
    push rsi
    .pushreg rsi
    push rdi
    .pushreg rdi
    sub rsp, 48
    .allocstack 48
    .endprolog
    mov rbx, rcx
    mov rcx, [rbx].WORKER.w_index
    call pin_current
    mov rsi, ctrl
    xor edi, edi                        ; last generation seen
wait_gen:
    mov ecx, SPIN_PAUSES
spin:
    cmp [rsi + CTRL_GEN], rdi
    jne go
    pause
    dec ecx
    jnz spin
    mov [rsp + 32], rdi
    mov rcx, rsi
    lea rdx, [rsp + 32]
    mov r8d, 8
    mov r9d, -1
    call WaitOnAddress
    jmp wait_gen
go:
    mov rdi, [rsi + CTRL_GEN]
    mov rdx, [rsi + CTRL_PHASE]
    cmp rdx, PH_EXIT
    je leave_thread
    mov rcx, rbx
    call worker_run
    lock dec qword ptr [rsi + CTRL_DONE]
    jmp wait_gen
leave_thread:
    lock dec qword ptr [rsi + CTRL_DONE]
    xor eax, eax
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret
worker_main ENDP

spawn_workers PROC FRAME
    push rbx
    .pushreg rbx
    push rsi
    .pushreg rsi
    sub rsp, 56
    .allocstack 56
    .endprolog
    xor ecx, ecx
    call pin_current
    mov rbx, g_workers
    mov esi, 1
next:
    cmp rsi, g_threads
    jae done
    add rbx, SIZEOF WORKER
    xor ecx, ecx
    xor edx, edx
    lea r8, worker_main
    mov r9, rbx
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    call CreateThread
    test rax, rax
    jnz @F
    FAIL "error: could not create worker thread"
@@: inc rsi
    jmp next
done:
    add rsp, 56
    pop rsi
    pop rbx
    ret
spawn_workers ENDP

; run_phase(rcx = phase) - run a phase on all workers and wait for them to finish
run_phase PROC FRAME
    push rbx
    .pushreg rbx
    push rsi
    .pushreg rsi
    sub rsp, 40
    .allocstack 40
    .endprolog
    mov rbx, rcx
    mov rsi, ctrl
    mov [rsi + CTRL_PHASE], rbx
    mov rax, g_threads
    dec rax
    mov [rsi + CTRL_DONE], rax
    lock inc qword ptr [rsi + CTRL_GEN]
    cmp g_threads, 1
    je local_work
    mov rcx, rsi
    call WakeByAddressAll
local_work:
    cmp rbx, PH_EXIT
    je wait_all
    mov rcx, g_workers
    mov rdx, rbx
    call worker_run
wait_all:
    cmp qword ptr [rsi + CTRL_DONE], 0
    je done
    pause
    jmp wait_all
done:
    add rsp, 40
    pop rsi
    pop rbx
    ret
run_phase ENDP

; tick_once() - run one tick and record its timings
tick_once PROC FRAME
    push rbx
    .pushreg rbx
    push rsi
    .pushreg rsi
    push rdi
    .pushreg rdi
    sub rsp, 32
    .allocstack 32
    .endprolog
    call tier_tick                      ; every worker is idle here, so patching is safe
    call now_qpc
    mov rbx, rax
    mov ecx, PH_INTEGRATE
    call run_phase
    call now_qpc
    mov rsi, rax
    call sim_grid_build
    call now_qpc
    mov rdi, rax
    mov ecx, PH_SNAPSHOT
    call run_phase
    call now_qpc

    mov rcx, rsi
    sub rcx, rbx
    add total_integrate, rcx
    mov rcx, rdi
    sub rcx, rsi
    add total_grid, rcx
    mov rcx, rax
    sub rcx, rdi
    add total_snap, rcx
    sub rax, rbx
    add total_tick, rax

    mov rcx, rax
    mov edx, 1000000
    mov r8, freq
    call muldiv
    cmp rax, max_tick_us
    jbe @F
    mov max_tick_us, rax
@@: mov ecx, HIST_BINS - 1
    cmp rax, rcx
    cmova rax, rcx
    mov rcx, hist
    inc dword ptr [rcx + rax*4]

    inc ticks_run
    inc g_tick
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
tick_once ENDP

; Forget everything recorded so far: warm-up must not count.
stats_reset PROC FRAME
    push rdi
    .pushreg rdi
    .endprolog
    xor eax, eax
    mov ticks_run, rax
    mov total_integrate, rax
    mov total_grid, rax
    mov total_snap, rax
    mov total_tick, rax
    mov max_tick_us, rax
    mov rdi, hist
    mov ecx, HIST_BINS
    rep stosd
    mov rdi, g_workers
    mov rcx, g_threads
next:
    mov [rdi].WORKER.w_rxpkts, rax
    mov [rdi].WORKER.w_rxbad, rax
    mov [rdi].WORKER.w_txpkts, rax
    mov [rdi].WORKER.w_txbytes, rax
    mov [rdi].WORKER.w_txfail, rax
    mov [rdi].WORKER.w_visible, rax
    mov [rdi].WORKER.w_capped, rax
    add rdi, SIZEOF WORKER
    dec rcx
    jnz next
    pop rdi
    ret
stats_reset ENDP

bench_loop PROC FRAME
    push rbx
    .pushreg rbx
    sub rsp, 32
    .allocstack 32
    .endprolog
    mov ebx, WARMUP_TICKS
warm:
    call tick_once
    dec ebx
    jnz warm
    call stats_reset
    mov rbx, arg_count
measure:
    call tick_once
    dec rbx
    jnz measure
    add rsp, 32
    pop rbx
    ret
bench_loop ENDP

; Fixed-rate loop: sleep until each deadline, and never try to "catch up".
serve_loop PROC FRAME
    push rbx
    .pushreg rbx
    push rsi
    .pushreg rsi
    push rdi
    .pushreg rdi
    push r12
    .pushreg r12
    sub rsp, 72
    .allocstack 72
    .endprolog
    xor ecx, ecx
    xor edx, edx
    mov r8d, 2                          ; CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
    mov r9d, 1F0003h                    ; TIMER_ALL_ACCESS
    call CreateWaitableTimerExW
    test rax, rax
    jnz @F
    FAIL "error: could not create high resolution timer"
@@: mov r12, rax
    mov rax, freq
    xor edx, edx
    div g_hz
    mov rdi, rax                        ; ticks of QPC per game tick
    mov rax, arg_count
    imul rax, g_hz
    mov rbx, rax                        ; game ticks left to run
    PRINT "serving on 127.0.0.1",13,10
    call now_qpc
    lea rsi, [rax + rdi]                ; next deadline
next:
    call now_qpc
    mov rcx, rsi
    sub rcx, rax
    jle run
    mov edx, 10000000                   ; QPC ticks -> 100 ns units
    mov r8, freq
    call muldiv
    test rax, rax
    jz run
    neg rax
    mov [rsp + 64], rax
    mov rcx, r12
    lea rdx, [rsp + 64]
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    call SetWaitableTimer
    mov rcx, r12
    mov edx, -1
    call WaitForSingleObject
run:
    call tick_once
    add rsi, rdi
    call now_qpc
    cmp rax, rsi
    jbe @F
    inc overruns
    mov rsi, rax
@@: dec rbx
    jnz next
    add rsp, 72
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
serve_loop ENDP

; ---- report ------------------------------------------------------------------

; percentile(rcx = per-mille) -> rax = tick time in microseconds
percentile PROC
    mov rax, ticks_run
    imul rax, rcx
    add rax, 999
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov r8, rax
    mov r9, hist
    xor ecx, ecx
    xor edx, edx
@@: mov eax, dword ptr [r9 + rcx*4]
    add rdx, rax
    cmp rdx, r8
    jae found
    inc rcx
    cmp rcx, HIST_BINS
    jb @B
found:
    mov rax, rcx
    ret
percentile ENDP

; sum_field(rcx = byte offset into WORKER) -> rax = total across workers
sum_field PROC
    mov rdx, g_workers
    mov r8, g_threads
    xor eax, eax
@@: add rax, [rdx + rcx]
    add rdx, SIZEOF WORKER
    dec r8
    jnz @B
    ret
sum_field ENDP

; qpc_avg_us(rcx = total QPC ticks) -> rax = average microseconds per tick
qpc_avg_us PROC FRAME
    sub rsp, 40
    .allocstack 40
    .endprolog
    mov edx, 1000000
    mov r8, freq
    call muldiv
    xor edx, edx
    mov rcx, ticks_run
    test rcx, rcx
    jz @F
    div rcx
@@: add rsp, 40
    ret
qpc_avg_us ENDP

REPORT_LINE MACRO text, value
    mov rbx, value                      ; PRINT clobbers volatile registers
    PRINT text
    mov rcx, rbx
    call print_u64
    PRINT 13,10
ENDM

report PROC FRAME
    push rbx
    .pushreg rbx
    sub rsp, 32
    .allocstack 32
    .endprolog
    REPORT_LINE "players          : ", g_players
    REPORT_LINE "threads          : ", g_threads
    REPORT_LINE "grid columns     : ", g_gw
    REPORT_LINE "ticks            : ", ticks_run

    mov rcx, total_tick
    call qpc_avg_us
    REPORT_LINE "tick avg us      : ", rax
    mov ecx, 500
    call percentile
    REPORT_LINE "tick p50 us      : ", rax
    mov ecx, 990
    call percentile
    REPORT_LINE "tick p99 us      : ", rax
    REPORT_LINE "tick max us      : ", max_tick_us
    mov rcx, total_integrate
    call qpc_avg_us
    REPORT_LINE "  integrate us   : ", rax
    mov rcx, total_grid
    call qpc_avg_us
    REPORT_LINE "  grid build us  : ", rax
    mov rcx, total_snap
    call qpc_avg_us
    REPORT_LINE "  snapshot us    : ", rax

    ; ns per player per tick = total_tick * 1e9 / freq / (ticks * players)
    mov rcx, total_tick
    mov edx, 1000000000
    mov r8, freq
    call muldiv
    mov rbx, ticks_run
    imul rbx, g_players
    xor edx, edx
    div rbx
    mov rcx, rbx
    mov rbx, rax
    mov [rsp + 32 + 16], rcx            ; shadow space of our caller: ticks * players
    PRINT "ns/player/tick   : "
    mov rcx, rbx
    call print_u64
    PRINT 13,10
    mov rbx, [rsp + 32 + 16]

    mov ecx, WORKER.w_visible
    call sum_field
    mov [rsp + 32 + 16], rax
    mov ecx, WORKER.w_txpkts
    call sum_field
    mov rcx, rax
    mov rax, [rsp + 32 + 16]
    xor edx, edx
    test rcx, rcx
    jz @F
    div rcx
@@:
    REPORT_LINE "avg entries/snap : ", rax
    mov ecx, WORKER.w_capped
    call sum_field
    REPORT_LINE "capped snapshots : ", rax
    mov ecx, WORKER.w_txpkts
    call sum_field
    REPORT_LINE "snapshots        : ", rax
    mov ecx, WORKER.w_txbytes
    call sum_field
    REPORT_LINE "snapshot bytes   : ", rax

    cmp g_serve, 0
    je done
    mov ecx, WORKER.w_rxpkts
    call sum_field
    REPORT_LINE "inputs received  : ", rax
    mov ecx, WORKER.w_rxbad
    call sum_field
    REPORT_LINE "inputs rejected  : ", rax
    mov ecx, WORKER.w_txfail
    call sum_field
    REPORT_LINE "send failures    : ", rax
    REPORT_LINE "tick overruns    : ", overruns
done:
    add rsp, 32
    pop rbx
    ret
report ENDP

; ---- entry point: no C runtime, the OS loader jumps straight here -------------

start PROC FRAME
    sub rsp, 40
    .allocstack 40
    .endprolog
    call print_init
    call cpu_check
    call parse_args
    call setup
    cmp high_priority, 0
    je @F
    ; Traces showed slow ticks are mostly pinned workers waking late or losing their core to
    ; normal-priority threads. Raising the priority removed both at 20,000 players.
    call GetCurrentProcess
    mov rcx, rax
    mov edx, 80h                        ; HIGH_PRIORITY_CLASS
    call SetPriorityClass
@@: call tier_init
    IFDEF TRACE
    call trace_alloc
    ENDIF
    call spawn_workers
    cmp g_serve, 0
    jne serving
    call bench_loop
    jmp finish
serving:
    call serve_loop
finish:
    mov ecx, PH_EXIT
    call run_phase
    call report
    call tier_report
    IFDEF TRACE
    call trace_dump
    ENDIF
    xor ecx, ecx
    call ExitProcess
    int 3
start ENDP

END
