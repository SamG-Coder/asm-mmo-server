; input.asm - checks and applies one input datagram. Shared by every network backend.
;
; Nothing from the network is trusted: bad sizes or magic, slots owned by another worker and
; old sequence numbers are dropped, and movement is clamped here so that a client can never
; exceed MAX_SPEED.
include defs.inc

.const
input_scale     REAL4 0.008             ; MAX_SPEED / INPUT_RANGE

.code

; input_apply(rcx = WORKER*, rdx = datagram, r8d = its length, r9 = 32-byte sender address)
input_apply PROC
    inc [rcx].WORKER.w_rxpkts
    cmp r8d, INPUT_SIZE
    jne bad
    cmp dword ptr [rdx], INPUT_MAGIC
    jne bad
    mov r10d, dword ptr [rdx + 4]       ; player
    cmp r10, [rcx].WORKER.w_first
    jb bad
    cmp r10, [rcx].WORKER.w_last
    jae bad

    mov r11, g_seq
    mov eax, dword ptr [rdx + 8]
    mov r8d, eax
    sub r8d, dword ptr [r11 + r10*4]
    jle done                            ; signed: survives sequence wraparound
    mov dword ptr [r11 + r10*4], eax

    mov rax, [rdx + 16]
    mov r11, g_echo
    mov [r11 + r10*8], rax

    mov r11, g_addr                     ; replies go to wherever the client is now
    mov rax, r10
    shl rax, ADDR_SHIFT
    movups xmm0, xmmword ptr [r9]
    movups xmm1, xmmword ptr [r9 + 16]
    movups xmmword ptr [r11 + rax], xmm0
    movups xmmword ptr [r11 + rax + 16], xmm1

    ; Velocity = clamp(input) * MAX_SPEED / INPUT_RANGE
    mov eax, INPUT_RANGE
    mov r8d, -INPUT_RANGE
    movsx r9d, word ptr [rdx + 12]
    cmp r9d, eax
    cmovg r9d, eax
    cmp r9d, r8d
    cmovl r9d, r8d
    cvtsi2ss xmm0, r9d
    movsx r9d, word ptr [rdx + 14]
    cmp r9d, eax
    cmovg r9d, eax
    cmp r9d, r8d
    cmovl r9d, r8d
    cvtsi2ss xmm1, r9d
    mulss xmm0, input_scale
    mulss xmm1, input_scale
    mov rax, g_vx
    movss dword ptr [rax + r10*4], xmm0
    mov rax, g_vy
    movss dword ptr [rax + r10*4], xmm1
    ret
bad:
    inc [rcx].WORKER.w_rxbad
done:
    ret
input_apply ENDP

END
