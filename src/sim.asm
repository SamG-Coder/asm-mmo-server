; sim.asm - the hot kernels: integration, spatial grid and area-of-interest query.
;
; Entities live in structure-of-arrays form. The grid is rebuilt from scratch each
; tick with a counting sort that copies positions into cell order, so a query is a
; linear scan of contiguous memory: the 3 cells of a grid row are adjacent in the
; sorted arrays, which turns a 3x3 lookup into 3 SIMD scans. Snapshot entries carry
; positions relative to the receiving player, computed from the same SIMD differences.
;
; These kernels use only ymm0-ymm5, which the Windows x64 ABI lets us clobber.
include defs.inc

.const
sign_bit dd 8 dup(80000000h)
rel_offset REAL4 2048.5                 ; centres relative positions, and rounds

.code

; One axis of: pos += vel * dt, clamp to the world, reflect velocity where clamped.
; ymm3 = 0, ymm4 = dt, ymm5 = largest legal coordinate
INTEGRATE_AXIS MACRO pos, vel
    vmovaps ymm1, ymmword ptr [vel + rcx*4]
    vmovaps ymm0, ymmword ptr [pos + rcx*4]
    vfmadd231ps ymm0, ymm1, ymm4
    vmaxps ymm2, ymm0, ymm3
    vminps ymm2, ymm2, ymm5
    vcmpneqps ymm0, ymm0, ymm2
    vandps ymm0, ymm0, ymmword ptr sign_bit
    vxorps ymm1, ymm1, ymm0
    vmovaps ymmword ptr [pos + rcx*4], ymm2
    vmovaps ymmword ptr [vel + rcx*4], ymm1
ENDM

; integrate_avx2(rcx = first slot, rdx = end slot). Both must be multiples of 8.
integrate_avx2 PROC
    cmp rcx, rdx
    jae done
    mov r8, g_px
    mov r9, g_vx
    mov r10, g_py
    mov r11, g_vy
    vxorps ymm3, ymm3, ymm3
    vbroadcastss ymm4, g_dt
    vbroadcastss ymm5, g_worldmax
next:
    INTEGRATE_AXIS r8, r9
    INTEGRATE_AXIS r10, r11
    add rcx, 8
    cmp rcx, rdx
    jb next
    vzeroupper
done:
    ret
integrate_avx2 ENDP

; integrate_scalar(rcx = first slot, rdx = end slot) - baseline x86-64, same rule
integrate_scalar PROC
    cmp rcx, rdx
    jae done
    mov r8, g_px
    mov r9, g_vx
    mov r10, g_py
    mov r11, g_vy
    movss xmm3, dword ptr sign_bit
    xorps xmm4, xmm4
    movss xmm5, g_worldmax
next:
    movss xmm0, dword ptr [r8 + rcx*4]
    movss xmm1, dword ptr [r9 + rcx*4]
    movaps xmm2, xmm1
    mulss xmm2, g_dt
    addss xmm0, xmm2
    movaps xmm2, xmm0
    maxss xmm2, xmm4
    minss xmm2, xmm5
    movss dword ptr [r8 + rcx*4], xmm2
    cmpneqss xmm0, xmm2
    andps xmm0, xmm3
    xorps xmm1, xmm0
    movss dword ptr [r9 + rcx*4], xmm1

    movss xmm0, dword ptr [r10 + rcx*4]
    movss xmm1, dword ptr [r11 + rcx*4]
    movaps xmm2, xmm1
    mulss xmm2, g_dt
    addss xmm0, xmm2
    movaps xmm2, xmm0
    maxss xmm2, xmm4
    minss xmm2, xmm5
    movss dword ptr [r10 + rcx*4], xmm2
    cmpneqss xmm0, xmm2
    andps xmm0, xmm3
    xorps xmm1, xmm0
    movss dword ptr [r11 + rcx*4], xmm1
    inc rcx
    cmp rcx, rdx
    jb next
done:
    ret
integrate_scalar ENDP

; cells_avx2() - cell index = (cy + 1) * stride + (cx + 1), eight entities at a time
cells_avx2 PROC
    mov r9, g_players
    mov r8, g_cell
    mov r10, g_px
    mov r11, g_py
    vbroadcastss ymm2, g_inv
    mov rax, g_gw
    dec eax
    vmovd xmm3, eax
    vpbroadcastd ymm3, xmm3             ; last valid column
    mov rax, g_stride
    vmovd xmm4, eax
    vpbroadcastd ymm4, xmm4
    inc eax
    vmovd xmm5, eax
    vpbroadcastd ymm5, xmm5             ; stride + 1
    xor ecx, ecx
next:
    vmulps ymm0, ymm2, ymmword ptr [r10 + rcx*4]
    vmulps ymm1, ymm2, ymmword ptr [r11 + rcx*4]
    vcvttps2dq ymm0, ymm0
    vcvttps2dq ymm1, ymm1
    vpminsd ymm0, ymm0, ymm3
    vpminsd ymm1, ymm1, ymm3
    vpmulld ymm1, ymm1, ymm4
    vpaddd ymm0, ymm0, ymm1
    vpaddd ymm0, ymm0, ymm5
    vmovdqa ymmword ptr [r8 + rcx*4], ymm0
    add rcx, 8
    cmp rcx, r9
    jb next
    vzeroupper
    ret
cells_avx2 ENDP

; cells_scalar() - the same, one entity at a time
cells_scalar PROC
    mov r9, g_players
    mov r8, g_cell
    mov r10, g_px
    mov r11, g_py
    movss xmm2, g_inv
    mov rax, g_gw
    lea edx, [rax - 1]                  ; last valid column
    xor ecx, ecx
next:
    movss xmm0, dword ptr [r10 + rcx*4]
    mulss xmm0, xmm2
    cvttss2si eax, xmm0
    cmp eax, edx
    cmovg eax, edx
    movss xmm0, dword ptr [r11 + rcx*4]
    mulss xmm0, xmm2
    cvttss2si r11d, xmm0
    cmp r11d, edx
    cmovg r11d, edx
    inc r11d
    imul r11d, dword ptr g_stride
    lea eax, [rax + r11 + 1]
    mov dword ptr [r8 + rcx*4], eax
    mov r11, g_py
    inc rcx
    cmp rcx, r9
    jb next
    ret
cells_scalar ENDP

; sim_grid_build() - counting sort of all entities into grid cells.
;
; Cells carry a one-cell empty border, so neighbour lookups need no bounds checks.
; After this returns, g_start[c] is the sorted index of the first entity in cell c.
sim_grid_build PROC FRAME
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

    ; 1. cell index of every entity
    call site_cells
    mov r12, g_players
    mov r8, g_cell
    mov r10, g_px
    mov r11, g_py

    ; 2. histogram, offset by 2 so that placement in step 4 leaves g_start correct
    mov r9, g_start
    mov rdi, r9
    mov rcx, g_ncells
    add rcx, 3
    xor eax, eax
    rep stosd
    xor ecx, ecx
count:
    mov eax, dword ptr [r8 + rcx*4]
    inc dword ptr [r9 + rax*4 + 8]
    inc rcx
    cmp rcx, r12
    jb count

    ; 3. prefix sum
    mov rcx, g_ncells
    add rcx, 3
    mov eax, 2
    xor edx, edx
prefix:
    add edx, dword ptr [r9 + rax*4]
    mov dword ptr [r9 + rax*4], edx
    inc rax
    cmp rax, rcx
    jb prefix

    ; 4. place: sorted positions and ids
    mov rsi, g_sx
    mov rdi, g_sy
    mov rbx, g_id
    xor ecx, ecx
place:
    mov eax, dword ptr [r8 + rcx*4]
    mov edx, dword ptr [r9 + rax*4 + 4]
    inc dword ptr [r9 + rax*4 + 4]
    mov r13d, dword ptr [r10 + rcx*4]
    mov dword ptr [rsi + rdx*4], r13d
    mov r13d, dword ptr [r11 + rcx*4]
    mov dword ptr [rdi + rdx*4], r13d
    mov dword ptr [rbx + rdx*4], ecx
    inc rcx
    cmp rcx, r12
    jb place

    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
sim_grid_build ENDP

; Query kernels: (rcx = slot, rdx = output) -> rax = entries written
;
; Each writes entries for entities within the AOI radius of the slot, g_entsize bytes each,
; in the same order. A SIMD tier may overshoot by up to one block: a result above
; MAX_VISIBLE means "capped", and the caller clamps the count, so all tiers send the same
; datagram. Output must have room for MAX_VISIBLE + 15 entries plus 2 spare bytes. Lower-
; numbered cells win when capped.
;
; Stack: [rsp] = packed positions for a block, [rsp + 64] = output.
QUERY_ENTER MACRO
    push rbx
    .pushreg rbx
    push rbp
    .pushreg rbp
    push rsi
    .pushreg rsi
    push rdi
    .pushreg rdi
    push r12
    .pushreg r12
    push r13
    .pushreg r13
    push r14
    .pushreg r14
    push r15
    .pushreg r15
    sub rsp, 72
    .allocstack 72
    .endprolog
    mov rdi, rdx
    mov [rsp + 64], rdx
    mov r14, g_entsize
    imul rax, r14, MAX_VISIBLE
    lea r12, [rdx + rax]                ; stop scanning once this is reached
    mov rax, g_cell
    mov r8d, dword ptr [rax + rcx*4]
    mov r9, g_start
    mov r10, g_sx
    mov r11, g_sy
    mov rbx, g_id
    mov r13, g_stride
    sub r8, r13                         ; begin at the row above
    mov edx, 3
ENDM

QUERY_LEAVE MACRO
    mov rax, rdi
    sub rax, [rsp + 64]
    xor edx, edx
    div r14
    add rsp, 72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
ENDM

; Emit each set bit of eax from the packed positions at [rsp], for the block at rsi.
QUERY_EMIT MACRO
    LOCAL emit
emit:
    tzcnt ecx, eax
    mov r15d, dword ptr [rsp + rcx*4]
    add rcx, rsi
    mov ecx, dword ptr [rbx + rcx*4]
    shl rcx, 24
    or rcx, r15
    mov qword ptr [rdi], rcx            ; 8 bytes written, but only g_entsize are kept
    add rdi, r14
    blsr eax, eax
    jnz emit
ENDM

; query_scalar - baseline x86-64: one candidate at a time, no block overshoot
query_scalar PROC FRAME
    mov rax, g_px
    movss xmm2, dword ptr [rax + rcx*4]
    mov rax, g_py
    movss xmm3, dword ptr [rax + rcx*4]
    QUERY_ENTER
row:
    mov esi, dword ptr [r9 + r8*4 - 4]  ; start of cell to the left
    mov ebp, dword ptr [r9 + r8*4 + 8]  ; end of cell to the right
scan:
    cmp rsi, rbp
    jae next_row
    movss xmm0, dword ptr [r10 + rsi*4]
    movss xmm1, dword ptr [r11 + rsi*4]
    subss xmm0, xmm2
    subss xmm1, xmm3
    movaps xmm4, xmm0
    movaps xmm5, xmm1
    mulss xmm4, xmm4
    mulss xmm5, xmm5
    addss xmm4, xmm5
    comiss xmm4, g_r2
    ja advance
    mulss xmm0, g_relscale
    mulss xmm1, g_relscale
    addss xmm0, rel_offset
    addss xmm1, rel_offset
    cvttss2si eax, xmm0
    cvttss2si ecx, xmm1
    shl ecx, 12
    or eax, ecx
    mov ecx, dword ptr [rbx + rsi*4]
    shl rcx, 24
    or rcx, rax
    mov qword ptr [rdi], rcx
    add rdi, r14
    cmp rdi, r12
    jae finished
advance:
    inc rsi
    jmp scan
next_row:
    add r8, r13
    dec edx
    jnz row
finished:
    QUERY_LEAVE
query_scalar ENDP

; query_avx2 - 8 candidates per block
query_avx2 PROC FRAME
    mov rax, g_px
    vbroadcastss ymm2, dword ptr [rax + rcx*4]
    mov rax, g_py
    vbroadcastss ymm3, dword ptr [rax + rcx*4]
    vbroadcastss ymm4, g_r2
    QUERY_ENTER
row:
    mov esi, dword ptr [r9 + r8*4 - 4]
    mov ebp, dword ptr [r9 + r8*4 + 8]
scan:
    cmp rsi, rbp
    jae next_row
    vmovups ymm0, ymmword ptr [r10 + rsi*4]
    vmovups ymm1, ymmword ptr [r11 + rsi*4]
    vsubps ymm0, ymm0, ymm2             ; dx
    vsubps ymm1, ymm1, ymm3             ; dy
    vmulps ymm5, ymm0, ymm0
    vfmadd231ps ymm5, ymm1, ymm1
    vcmpleps ymm5, ymm5, ymm4
    vmovmskps eax, ymm5
    mov rcx, rbp
    sub rcx, rsi
    cmp rcx, 8
    jae whole_block
    bzhi eax, eax, ecx                  ; last block: drop lanes past the range
whole_block:
    test eax, eax
    jz advance

    ; Encode all lanes at once: 12 bits of dx, then 12 bits of dy.
    vbroadcastss ymm5, g_relscale
    vmulps ymm0, ymm0, ymm5
    vmulps ymm1, ymm1, ymm5
    vbroadcastss ymm5, rel_offset
    vaddps ymm0, ymm0, ymm5
    vaddps ymm1, ymm1, ymm5
    vcvttps2dq ymm0, ymm0
    vcvttps2dq ymm1, ymm1
    vpslld ymm1, ymm1, 12
    vpor ymm0, ymm0, ymm1
    vmovdqu ymmword ptr [rsp], ymm0
    QUERY_EMIT
    cmp rdi, r12
    jae finished
advance:
    add rsi, 8
    jmp scan
next_row:
    add r8, r13
    dec edx
    jnz row
finished:
    vzeroupper
    QUERY_LEAVE
query_avx2 ENDP

; query_avx512 - 16 candidates per block
query_avx512 PROC FRAME
    mov rax, g_px
    vbroadcastss zmm2, dword ptr [rax + rcx*4]
    mov rax, g_py
    vbroadcastss zmm3, dword ptr [rax + rcx*4]
    vbroadcastss zmm4, g_r2
    QUERY_ENTER
row:
    mov esi, dword ptr [r9 + r8*4 - 4]
    mov ebp, dword ptr [r9 + r8*4 + 8]
scan:
    cmp rsi, rbp
    jae next_row
    vmovups zmm0, zmmword ptr [r10 + rsi*4]
    vmovups zmm1, zmmword ptr [r11 + rsi*4]
    vsubps zmm0, zmm0, zmm2
    vsubps zmm1, zmm1, zmm3
    vmulps zmm5, zmm0, zmm0
    vfmadd231ps zmm5, zmm1, zmm1
    vcmpps k1, zmm5, zmm4, 2            ; less or equal
    kmovw eax, k1
    mov rcx, rbp
    sub rcx, rsi
    cmp rcx, 16
    jae whole_block
    bzhi eax, eax, ecx
whole_block:
    test eax, eax
    jz advance

    vbroadcastss zmm5, g_relscale
    vmulps zmm0, zmm0, zmm5
    vmulps zmm1, zmm1, zmm5
    vbroadcastss zmm5, rel_offset
    vaddps zmm0, zmm0, zmm5
    vaddps zmm1, zmm1, zmm5
    vcvttps2dq zmm0, zmm0
    vcvttps2dq zmm1, zmm1
    vpslld zmm1, zmm1, 12
    vpord zmm0, zmm0, zmm1
    vmovdqu32 zmmword ptr [rsp], zmm0
    QUERY_EMIT
    cmp rdi, r12
    jae finished
advance:
    add rsi, 16
    jmp scan
next_row:
    add r8, r13
    dec edx
    jnz row
finished:
    vzeroupper
    QUERY_LEAVE
query_avx512 ENDP

END
