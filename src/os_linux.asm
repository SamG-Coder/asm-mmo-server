; os_linux.asm - everything the server needs from Linux, apart from sockets (net_linux.asm).
;
; Same functions as os_windows.asm, using raw system calls: no libc is linked. Arguments use
; rcx, rdx, r8, r9, as everywhere else in the server. System calls take theirs in rdi, rsi, rdx,
; r10, r8, r9, and clobber rcx and r11, so these functions save rdi and rsi where they use them.
include defs.inc

SYS_WRITE           equ 1
SYS_MMAP            equ 9
SYS_MPROTECT        equ 10
SYS_CLONE           equ 56
SYS_EXIT            equ 60
SYS_SETPRIORITY     equ 141
SYS_FUTEX           equ 202
SYS_SCHED_SETAFFINITY equ 203
SYS_SCHED_GETAFFINITY equ 204
SYS_CLOCK_GETTIME   equ 228
SYS_CLOCK_NANOSLEEP equ 230
SYS_EXIT_GROUP      equ 231

CLOCK_MONOTONIC     equ 1
FUTEX_WAIT_PRIVATE  equ 128
FUTEX_WAKE_PRIVATE  equ 129
; CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD | CLONE_SYSVSEM
THREAD_FLAGS        equ 50F00h
THREAD_STACK        equ 1048576
ARGS_BUFFER         equ 4096
AFFINITY_BYTES      equ 128

.data
initial_stack   dq 0
args_buffer     db ARGS_BUFFER dup(0)

.code

; The kernel starts the process here, with argc and argv on the stack.
_start PROC
    mov initial_stack, rsp
    and rsp, -16
    call start
    mov edi, 1
    mov eax, SYS_EXIT_GROUP
    syscall
_start ENDP

; os_init() - nothing to prepare on Linux
os_init PROC
    ret
os_init ENDP

; os_args() -> rax = the arguments after the program name, joined by spaces
os_args PROC
    push rsi
    push rdi
    mov r8, initial_stack
    mov r9, [r8]                        ; argc
    lea rdi, args_buffer
    lea r10, [rdi + ARGS_BUFFER - 2]    ; room for a space and the terminator
    mov ecx, 1
next_arg:
    cmp rcx, r9
    jae finished
    mov rsi, [r8 + rcx*8 + 8]
    mov byte ptr [rdi], ' '
    inc rdi
copy:
    cmp rdi, r10
    jae finished
    mov al, [rsi]
    test al, al
    jz copied
    mov [rdi], al
    inc rsi
    inc rdi
    jmp copy
copied:
    inc rcx
    jmp next_arg
finished:
    mov byte ptr [rdi], 0
    lea rax, args_buffer
    pop rdi
    pop rsi
    ret
os_args ENDP

; os_write(rcx = text, rdx = bytes) - write to stdout
os_write PROC
    push rsi
    push rdi
    mov rsi, rcx
next:
    test rdx, rdx
    jz done
    mov edi, 1
    mov eax, SYS_WRITE
    push rdx
    syscall
    pop rdx
    test rax, rax
    jle done
    add rsi, rax
    sub rdx, rax
    jmp next
done:
    pop rdi
    pop rsi
    ret
os_write ENDP

; os_exit(ecx = status) - never returns
os_exit PROC
    mov edi, ecx
    mov eax, SYS_EXIT_GROUP
    syscall
    int 3
os_exit ENDP

; os_alloc(rcx = bytes) -> rax = page-aligned, zeroed memory, or 0
os_alloc PROC
    push rsi
    push rdi
    xor edi, edi
    mov rsi, rcx
    mov edx, 3                          ; PROT_READ | PROT_WRITE
    mov r10d, 22h                       ; MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    mov eax, SYS_MMAP
    syscall
    cmp rax, -4096                      ; errors are returned as -4095 to -1
    jbe @F
    xor eax, eax
@@: pop rdi
    pop rsi
    ret
os_alloc ENDP

; now_qpc() -> rax = monotonic clock in nanoseconds
now_qpc PROC
    push rsi
    push rdi
    sub rsp, 16
    mov edi, CLOCK_MONOTONIC
    mov rsi, rsp
    mov eax, SYS_CLOCK_GETTIME
    syscall
    imul rax, qword ptr [rsp], 1000000000
    add rax, [rsp + 8]
    add rsp, 16
    pop rdi
    pop rsi
    ret
now_qpc ENDP

; os_freq() -> rax = clock ticks per second
os_freq PROC
    mov eax, 1000000000
    ret
os_freq ENDP

; os_cpu_count() -> rax = CPUs this process may use
os_cpu_count PROC
    push rsi
    push rdi
    sub rsp, AFFINITY_BYTES
    xor edi, edi
    mov esi, AFFINITY_BYTES
    mov rdx, rsp
    mov eax, SYS_SCHED_GETAFFINITY
    syscall
    xor r8d, r8d                        ; CPUs counted
    test rax, rax
    jle done
    xor ecx, ecx                        ; bytes examined
each_byte:
    cmp rcx, rax
    jae done
    movzx edx, byte ptr [rsp + rcx]
each_bit:
    test edx, edx
    jz next_byte
    mov r9d, edx
    and r9d, 1
    add r8, r9
    shr edx, 1
    jmp each_bit
next_byte:
    inc rcx
    jmp each_byte
done:
    mov eax, 1
    test r8, r8
    cmovnz rax, r8
    add rsp, AFFINITY_BYTES
    pop rdi
    pop rsi
    ret
os_cpu_count ENDP

; os_pin(rcx = logical CPU) - keep the calling thread on one CPU. Failure is harmless: a
; container may not allow every CPU, and the thread then simply stays unpinned.
os_pin PROC
    push rsi
    push rdi
    sub rsp, AFFINITY_BYTES
    mov rdi, rsp
    mov r8, rcx
    mov ecx, AFFINITY_BYTES / 8
    xor eax, eax
    rep stosq
    mov rax, r8
    shr rax, 6
    mov ecx, r8d
    and ecx, 63
    mov edx, 1
    shl rdx, cl
    mov [rsp + rax*8], rdx
    xor edi, edi                        ; the calling thread
    mov esi, AFFINITY_BYTES
    mov rdx, rsp
    mov eax, SYS_SCHED_SETAFFINITY
    syscall
    add rsp, AFFINITY_BYTES
    pop rdi
    pop rsi
    ret
os_pin ENDP

; os_spawn(rcx = function taking rcx, rdx = its argument) -> rax = 0 on failure
os_spawn PROC
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov r12, rcx
    mov r13, rdx
    mov ecx, THREAD_STACK
    call os_alloc
    test rax, rax
    jz done
    lea rsi, [rax + THREAD_STACK - 16]  ; the new thread pops these two values
    mov [rsi], r12
    mov [rsi + 8], r13
    mov edi, THREAD_FLAGS
    xor edx, edx
    xor r10d, r10d
    xor r8d, r8d
    mov eax, SYS_CLONE
    syscall
    test rax, rax
    jz child
    js failed
    mov eax, 1
    jmp done
failed:
    xor eax, eax
done:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    ret
child:
    pop rax                             ; function
    pop rcx                             ; argument; the stack is now 16-byte aligned
    call rax
    xor edi, edi
    mov eax, SYS_EXIT                   ; ends this thread only
    syscall
    int 3
os_spawn ENDP

; os_wait(rcx = address, rdx = expected value) - sleep while the value still holds. Futexes
; compare 32 bits, which is enough for a generation counter. May return early.
os_wait PROC
    push rsi
    push rdi
    mov rdi, rcx
    mov esi, FUTEX_WAIT_PRIVATE
    xor r10d, r10d                      ; no timeout
    xor r8d, r8d
    xor r9d, r9d
    mov eax, SYS_FUTEX
    syscall
    pop rdi
    pop rsi
    ret
os_wait ENDP

; os_wake(rcx = address) - wake every thread in os_wait on it
os_wake PROC
    push rsi
    push rdi
    mov rdi, rcx
    mov esi, FUTEX_WAKE_PRIVATE
    mov edx, 7FFFFFFFh
    xor r10d, r10d
    xor r8d, r8d
    xor r9d, r9d
    mov eax, SYS_FUTEX
    syscall
    pop rdi
    pop rsi
    ret
os_wake ENDP

; os_sleep(rcx = time in 100 ns units)
os_sleep PROC
    push rsi
    push rdi
    sub rsp, 16
    mov rax, rcx
    xor edx, edx
    mov ecx, 10000000
    div rcx
    mov [rsp], rax                      ; seconds
    imul rdx, rdx, 100
    mov [rsp + 8], rdx                  ; nanoseconds
    mov edi, CLOCK_MONOTONIC
    xor esi, esi                        ; relative
    mov rdx, rsp
    xor r10d, r10d
    mov eax, SYS_CLOCK_NANOSLEEP
    syscall
    add rsp, 16
    pop rdi
    pop rsi
    ret
os_sleep ENDP

; os_raise_priority() -> eax = nonzero on success. Needs CAP_SYS_NICE or a matching
; RLIMIT_NICE, so this can fail for ordinary users. New threads inherit the value.
os_raise_priority PROC
    push rsi
    push rdi
    xor edi, edi                        ; PRIO_PROCESS
    xor esi, esi                        ; the calling thread
    mov rdx, -10
    mov eax, SYS_SETPRIORITY
    syscall
    xor ecx, ecx
    test rax, rax
    sete cl
    mov eax, ecx
    pop rdi
    pop rsi
    ret
os_raise_priority ENDP

; os_code_writable(rcx = code address) -> eax = nonzero on success. The whole page stays
; executable meanwhile, as the linker might place other code in it.
os_code_writable PROC
    mov edx, 7                          ; PROT_READ | PROT_WRITE | PROT_EXEC
    jmp set_protection
os_code_writable ENDP

; os_code_executable(rcx = code address) -> eax = nonzero on success. x86 keeps instruction
; caches coherent, and this call also serializes the thread that made the change.
os_code_executable PROC
    mov edx, 5                          ; PROT_READ | PROT_EXEC
    jmp set_protection
os_code_executable ENDP

set_protection PROC
    push rsi
    push rdi
    mov rdi, rcx
    and rdi, -4096
    mov esi, 4096
    mov eax, SYS_MPROTECT
    syscall
    xor ecx, ecx
    test rax, rax
    sete cl
    mov eax, ecx
    pop rdi
    pop rsi
    ret
set_protection ENDP

END
