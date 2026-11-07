; os_windows.asm - everything the server needs from Windows, apart from sockets (net.asm).
;
; os_linux.asm provides the same functions. Arguments use rcx, rdx, r8, r9 on both systems,
; and rbx, rbp, rsi, rdi and r12-r15 are preserved, so the rest of the server doesn't need to
; know which system it runs on.
include defs.inc

.data
stdout_handle   dq 0
sleep_timer     dq 0

.code

; os_init() - call once, first
os_init PROC FRAME
    sub rsp, 40
    .allocstack 40
    .endprolog
    mov ecx, -11                        ; STD_OUTPUT_HANDLE
    call GetStdHandle
    mov stdout_handle, rax
    xor ecx, ecx
    xor edx, edx
    mov r8d, 2                          ; CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
    mov r9d, 1F0003h                    ; TIMER_ALL_ACCESS
    call CreateWaitableTimerExW
    mov sleep_timer, rax
    test rax, rax
    jnz @F
    FAIL "error: could not create high resolution timer"
@@: add rsp, 40
    ret
os_init ENDP

; os_args() -> rax = the command line after the program name, zero-terminated
os_args PROC FRAME
    sub rsp, 40
    .allocstack 40
    .endprolog
    call GetCommandLineA
    cmp byte ptr [rax], '"'             ; the program name may be quoted
    jne plain
    inc rax
quoted:
    mov cl, [rax]
    test cl, cl
    jz done
    inc rax
    cmp cl, '"'
    jne quoted
    jmp done
plain:
    mov cl, [rax]
    test cl, cl
    jz done
    cmp cl, ' '
    je done
    inc rax
    jmp plain
done:
    add rsp, 40
    ret
os_args ENDP

; os_write(rcx = text, rdx = bytes) - write to stdout
os_write PROC FRAME
    sub rsp, 56
    .allocstack 56
    .endprolog
    mov r8, rdx
    mov rdx, rcx
    mov rcx, stdout_handle
    lea r9, [rsp + 40]
    mov qword ptr [rsp + 32], 0
    call WriteFile
    add rsp, 56
    ret
os_write ENDP

; os_exit(ecx = status) - never returns
os_exit PROC FRAME
    sub rsp, 40
    .allocstack 40
    .endprolog
    call ExitProcess
    int 3
os_exit ENDP

; os_alloc(rcx = bytes) -> rax = page-aligned, zeroed memory, or 0
os_alloc PROC FRAME
    sub rsp, 40
    .allocstack 40
    .endprolog
    mov rdx, rcx
    xor ecx, ecx
    mov r8d, 3000h                      ; MEM_COMMIT | MEM_RESERVE
    mov r9d, 4                          ; PAGE_READWRITE
    call VirtualAlloc
    add rsp, 40
    ret
os_alloc ENDP

; now_qpc() -> rax = monotonic clock; os_freq gives its ticks per second
now_qpc PROC FRAME
    sub rsp, 56
    .allocstack 56
    .endprolog
    lea rcx, [rsp + 32]
    call QueryPerformanceCounter
    mov rax, [rsp + 32]
    add rsp, 56
    ret
now_qpc ENDP

; os_freq() -> rax = clock ticks per second
os_freq PROC FRAME
    sub rsp, 56
    .allocstack 56
    .endprolog
    lea rcx, [rsp + 32]
    call QueryPerformanceFrequency
    mov rax, [rsp + 32]
    add rsp, 56
    ret
os_freq ENDP

; os_cpu_count() -> rax = logical CPUs
os_cpu_count PROC FRAME
    sub rsp, 88
    .allocstack 88
    .endprolog
    lea rcx, [rsp + 32]
    call GetSystemInfo
    mov eax, dword ptr [rsp + 32 + 32]  ; SYSTEM_INFO.dwNumberOfProcessors
    add rsp, 88
    ret
os_cpu_count ENDP

; os_pin(rcx = logical CPU) - keep the calling thread on one CPU
os_pin PROC FRAME
    push rbx
    .pushreg rbx
    sub rsp, 32
    .allocstack 32
    .endprolog
    mov eax, 1
    shl rax, cl
    mov rbx, rax
    call GetCurrentThread
    mov rcx, rax
    mov rdx, rbx
    call SetThreadAffinityMask
    add rsp, 32
    pop rbx
    ret
os_pin ENDP

; os_spawn(rcx = function taking rcx, rdx = its argument) -> rax = 0 on failure
os_spawn PROC FRAME
    sub rsp, 56
    .allocstack 56
    .endprolog
    mov r8, rcx
    mov r9, rdx
    xor ecx, ecx
    xor edx, edx
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    call CreateThread
    add rsp, 56
    ret
os_spawn ENDP

; os_wait(rcx = address, rdx = expected value) - sleep while the qword still holds that value.
; May return early, so callers must re-check.
os_wait PROC FRAME
    sub rsp, 56
    .allocstack 56
    .endprolog
    mov [rsp + 40], rdx
    lea rdx, [rsp + 40]
    mov r8d, 8
    mov r9d, -1
    call WaitOnAddress
    add rsp, 56
    ret
os_wait ENDP

; os_wake(rcx = address) - wake every thread in os_wait on it
os_wake PROC FRAME
    sub rsp, 40
    .allocstack 40
    .endprolog
    call WakeByAddressAll
    add rsp, 40
    ret
os_wake ENDP

; os_sleep(rcx = time in 100 ns units)
os_sleep PROC FRAME
    sub rsp, 56
    .allocstack 56
    .endprolog
    neg rcx                             ; negative means relative to now
    mov [rsp + 48], rcx
    mov rcx, sleep_timer
    lea rdx, [rsp + 48]
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    call SetWaitableTimer
    mov rcx, sleep_timer
    mov edx, -1
    call WaitForSingleObject
    add rsp, 56
    ret
os_sleep ENDP

; os_raise_priority() -> eax = nonzero on success
os_raise_priority PROC FRAME
    sub rsp, 40
    .allocstack 40
    .endprolog
    call GetCurrentProcess
    mov rcx, rax
    mov edx, 80h                        ; HIGH_PRIORITY_CLASS
    call SetPriorityClass
    add rsp, 40
    ret
os_raise_priority ENDP

; os_code_writable(rcx = code address) -> eax = nonzero on success
os_code_writable PROC FRAME
    sub rsp, 56
    .allocstack 56
    .endprolog
    mov edx, 5
    mov r8d, 4                          ; PAGE_READWRITE
    lea r9, [rsp + 40]
    call VirtualProtect
    add rsp, 56
    ret
os_code_writable ENDP

; os_code_executable(rcx = code address) -> eax = nonzero on success
os_code_executable PROC FRAME
    push rbx
    .pushreg rbx
    sub rsp, 48
    .allocstack 48
    .endprolog
    mov rbx, rcx
    mov edx, 5
    mov r8d, 20h                        ; PAGE_EXECUTE_READ
    lea r9, [rsp + 40]
    call VirtualProtect
    test eax, eax
    jz done
    call GetCurrentProcess
    mov rcx, rax
    mov rdx, rbx
    mov r8d, 5
    call FlushInstructionCache
done:
    add rsp, 48
    pop rbx
    ret
os_code_executable ENDP

; os_thread_cycles() -> rax = CPU cycles this thread has used. Trace build only.
os_thread_cycles PROC FRAME
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
os_thread_cycles ENDP

; os_write_file(rcx = zero-terminated name, rdx = data, r8 = bytes). Trace build only.
os_write_file PROC FRAME
    push rsi
    .pushreg rsi
    push rdi
    .pushreg rdi
    sub rsp, 72
    .allocstack 72
    .endprolog
    mov rsi, rdx
    mov rdi, r8
    mov edx, 40000000h                  ; GENERIC_WRITE
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 2         ; CREATE_ALWAYS
    mov qword ptr [rsp + 40], 80h       ; FILE_ATTRIBUTE_NORMAL
    mov qword ptr [rsp + 48], 0
    call CreateFileA
    mov rcx, rax
    mov rdx, rsi
    mov r8, rdi
    lea r9, [rsp + 56]
    mov qword ptr [rsp + 32], 0
    call WriteFile
    add rsp, 72
    pop rdi
    pop rsi
    ret
os_write_file ENDP

END
