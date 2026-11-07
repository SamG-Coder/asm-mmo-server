; util.asm - console output, memory, time, randomness and the CPU feature check.
include defs.inc

.data
stdout_handle   dq 0
rng_state       dq 9E3779B97F4A7C15h    ; fixed seed: benchmark runs are repeatable

.code

print_init PROC FRAME
    sub rsp, 40
    .allocstack 40
    .endprolog
    mov ecx, -11                        ; STD_OUTPUT_HANDLE
    call GetStdHandle
    mov stdout_handle, rax
    add rsp, 40
    ret
print_init ENDP

; print_str(rcx = zero-terminated string)
print_str PROC FRAME
    sub rsp, 56
    .allocstack 56
    .endprolog
    mov rdx, rcx
    xor r8d, r8d
@@: cmp byte ptr [rdx + r8], 0
    je @F
    inc r8
    jmp @B
@@: mov rcx, stdout_handle
    lea r9, [rsp + 40]
    mov qword ptr [rsp + 32], 0
    call WriteFile
    add rsp, 56
    ret
print_str ENDP

; print_u64(rcx = value)
print_u64 PROC FRAME
    sub rsp, 72
    .allocstack 72
    .endprolog
    mov rax, rcx
    lea r8, [rsp + 63]
    mov byte ptr [r8], 0
    mov r9d, 10
@@: xor edx, edx
    div r9
    add dl, '0'
    dec r8
    mov [r8], dl
    test rax, rax
    jnz @B
    mov rcx, r8
    call print_str
    add rsp, 72
    ret
print_u64 ENDP

; die(rcx = message) - never returns
die PROC FRAME
    sub rsp, 40
    .allocstack 40
    .endprolog
    call print_str
    mov ecx, 1
    call ExitProcess
    int 3
die ENDP

; alloc_zeroed(rcx = bytes) -> rax = page-aligned, zeroed memory. Exits on failure.
alloc_zeroed PROC FRAME
    sub rsp, 40
    .allocstack 40
    .endprolog
    mov rdx, rcx
    xor ecx, ecx
    mov r8d, 3000h                      ; MEM_COMMIT | MEM_RESERVE
    mov r9d, 4                          ; PAGE_READWRITE
    call VirtualAlloc
    test rax, rax
    jnz @F
    FAIL "error: out of memory"
@@: add rsp, 40
    ret
alloc_zeroed ENDP

; now_qpc() -> rax = performance counter
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

; muldiv(rcx, rdx, r8) -> rax = rcx * rdx / r8, with a 128-bit intermediate.
; r8 = 0 yields 0, so reports stay valid when nothing was counted.
muldiv PROC
    test r8, r8
    jz zero
    mov rax, rcx
    mul rdx
    div r8
    ret
zero:
    xor eax, eax
    ret
muldiv ENDP

; rand32() -> eax = xorshift64* output. Startup only: not thread safe.
rand32 PROC
    mov rax, rng_state
    mov rdx, rax
    shl rdx, 13
    xor rax, rdx
    mov rdx, rax
    shr rdx, 7
    xor rax, rdx
    mov rdx, rax
    shl rdx, 17
    xor rax, rdx
    mov rng_state, rax
    mov rdx, 2545F4914F6CDD1Dh
    imul rax, rdx
    shr rax, 32
    ret
rand32 ENDP

; cpu_check() - set g_cpu_level: 0 = baseline x86-64, 1 = AVX2 kernels (with FMA, BMI1 and
; BMI2), 2 = AVX-512 kernels too. Every x86-64 CPU can run level 0.
cpu_check PROC FRAME
    push rbx                            ; cpuid clobbers rbx
    .pushreg rbx
    sub rsp, 32
    .allocstack 32
    .endprolog
    mov g_cpu_level, 0
    xor eax, eax
    cpuid
    cmp eax, 7
    jb done
    mov eax, 1
    cpuid
    and ecx, 18001000h                  ; FMA, OSXSAVE, AVX
    cmp ecx, 18001000h
    jne done
    xor ecx, ecx
    xgetbv
    mov r8d, eax
    and eax, 6                          ; OS saves XMM and YMM state
    cmp eax, 6
    jne done
    mov eax, 7
    xor ecx, ecx
    cpuid
    mov eax, ebx
    and eax, 128h                       ; BMI1, AVX2, BMI2
    cmp eax, 128h
    jne done
    mov g_cpu_level, 1
    test ebx, 10000h                    ; AVX-512F
    jz done
    and r8d, 0E0h                       ; OS saves opmask and ZMM state
    cmp r8d, 0E0h
    jne done
    mov g_cpu_level, 2
done:
    add rsp, 32
    pop rbx
    ret
cpu_check ENDP

END
