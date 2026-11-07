; tier.asm - runtime code selection: the server rewrites its own jumps.
;
; Hot kernels are reached through "sites": a single jmp rel32 in a dedicated code page.
; Startup patches each site to the best kernel the CPU supports. While running, the query
; site is re-chosen from live measurements:
;
;   1. Every PROFILE_EVERY ticks, patch the site to a timing wrapper.
;   2. Run one tick per available tier, recording cycles per query.
;   3. Patch the site straight to the winner. The wrapper is gone, so timing costs nothing
;      outside these few ticks.
;
; Patching is safe because it only happens between phases, on the main thread, while every
; worker is waiting outside these kernels. tier_tick must only be called at that point.
include defs.inc

PROFILE_EVERY   equ 512
FIRST_PROFILE   equ 8
SWITCH_PERCENT  equ 95                  ; a rival must be this fraction of the current cost
TIERS           equ 3
TIER_AUTO       equ 3
PAGE_READWRITE  equ 4
PAGE_EXECUTE_READ equ 20h

; Own page: changing its protection can't affect any other code.
_SITES SEGMENT ALIGN(4096) READ EXECUTE 'CODE'
site_query PROC
    db 0E9h
    dd 0
site_query ENDP
    db 11 dup(0CCh)
site_integrate PROC
    db 0E9h
    dd 0
site_integrate ENDP
    db 11 dup(0CCh)
site_cells PROC
    db 0E9h
    dd 0
site_cells ENDP
_SITES ENDS

.const
query_table dq query_scalar, query_avx2, query_avx512
name_scalar db "scalar", 0
name_avx2   db "AVX2", 0
name_avx512 db "AVX-512", 0
tier_names  dq name_scalar, name_avx2, name_avx512

.data
top_tier    dq 0                        ; best tier allowed here
current     dq 0                        ; tier the query site points at
adaptive    dq 0
countdown   dq FIRST_PROFILE
trial       dq 0                        ; 0 = not profiling, else tier being timed + 1
prof_target dq 0
prof_cost   dq TIERS dup(0)             ; cycles per query from the last profile
switches    dq 0
patches     dq 0

.code

; patch_site(rcx = site, rdx = target) - point a site's jmp at a new kernel
patch_site PROC FRAME
    push rbx
    .pushreg rbx
    push rsi
    .pushreg rsi
    sub rsp, 56
    .allocstack 56
    .endprolog
    mov rbx, rcx
    mov rsi, rdx
    mov edx, 5
    mov r8d, PAGE_READWRITE
    lea r9, [rsp + 40]
    call VirtualProtect
    test eax, eax
    jnz @F
    FAIL "error: could not make the code page writable"
@@: mov rax, rsi
    sub rax, rbx
    sub rax, 5
    mov byte ptr [rbx], 0E9h
    mov dword ptr [rbx + 1], eax
    mov rcx, rbx
    mov edx, 5
    mov r8d, PAGE_EXECUTE_READ
    lea r9, [rsp + 40]
    call VirtualProtect
    test eax, eax
    jnz @F
    FAIL "error: could not restore the code page"
@@: call GetCurrentProcess
    mov rcx, rax
    mov rdx, rbx
    mov r8d, 5
    call FlushInstructionCache
    inc patches
    add rsp, 56
    pop rsi
    pop rbx
    ret
patch_site ENDP

; query_profiled(rcx = slot, rdx = output, r8 = WORKER*) - time one query.
; The site only points here during profiling ticks.
query_profiled PROC FRAME
    push rbx
    .pushreg rbx
    push rsi
    .pushreg rsi
    push rdi
    .pushreg rdi
    push r12
    .pushreg r12
    sub rsp, 40
    .allocstack 40
    .endprolog
    mov rbx, r8
    mov rsi, rcx
    mov rdi, rdx
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov r12, rax
    mov rcx, rsi
    mov rdx, rdi
    call prof_target
    mov rsi, rax
    rdtsc
    shl rdx, 32
    or rax, rdx
    sub rax, r12
    add [rbx].WORKER.w_profcycles, rax
    inc [rbx].WORKER.w_profcount
    mov rax, rsi
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
query_profiled ENDP

; tier_init() - pick starting kernels. Call before any worker thread exists.
tier_init PROC FRAME
    sub rsp, 40
    .allocstack 40
    .endprolog
    mov rax, g_cpu_level
    mov rcx, g_force_tier
    cmp rcx, TIER_AUTO
    je automatic
    cmp rcx, rax
    cmovb rax, rcx                      ; a forced tier can't exceed what the CPU supports
    jmp chosen
automatic:
    mov adaptive, 1
chosen:
    mov top_tier, rax
    mov current, rax

    lea rcx, site_query
    lea rdx, query_table
    mov rdx, [rdx + rax*8]
    call patch_site

    lea rdx, integrate_scalar
    cmp top_tier, 0
    je @F
    lea rdx, integrate_avx2
@@: lea rcx, site_integrate
    call patch_site

    lea rdx, cells_scalar
    cmp top_tier, 0
    je @F
    lea rdx, cells_avx2
@@: lea rcx, site_cells
    call patch_site
    add rsp, 40
    ret
tier_init ENDP

; take_sample() -> rax = cycles per query since the last call, 0 if there were no queries.
; Resets the counters.
take_sample PROC
    mov rcx, g_workers
    mov r8, g_threads
    xor r9d, r9d                        ; cycles
    xor r10d, r10d                      ; queries
@@: add r9, [rcx].WORKER.w_profcycles
    add r10, [rcx].WORKER.w_profcount
    mov [rcx].WORKER.w_profcycles, 0
    mov [rcx].WORKER.w_profcount, 0
    add rcx, SIZEOF WORKER
    dec r8
    jnz @B
    xor eax, eax
    test r10, r10
    jz none
    mov rax, r9
    xor edx, edx
    div r10
none:
    ret
take_sample ENDP

; tier_tick() - advance profiling. Only call between ticks, with workers idle.
tier_tick PROC FRAME
    sub rsp, 40
    .allocstack 40
    .endprolog
    cmp adaptive, 0
    je done
    cmp trial, 0
    jne timing

    dec countdown
    jnz done
    call take_sample                    ; discard anything stale
    lea rax, query_table
    mov rax, [rax]
    mov prof_target, rax
    mov trial, 1
    lea rcx, site_query
    lea rdx, query_profiled
    call patch_site
    jmp done

timing:
    call take_sample
    mov rcx, trial
    lea rdx, prof_cost
    mov [rdx + rcx*8 - 8], rax
    cmp rcx, top_tier
    ja decide                           ; trial is tier + 1, so this was the last tier
    lea rax, query_table
    mov rax, [rax + rcx*8]
    mov prof_target, rax
    inc trial
    jmp done

decide:
    ; Keep the current tier unless a rival is clearly cheaper, so noise can't cause churn.
    ; No queries at all (an idle server) also leaves it alone.
    lea r8, prof_cost
    mov r9, current
    mov r10, r9                         ; best tier
    mov r11, [r8 + r9*8]                ; its cost, scaled by SWITCH_PERCENT below
    imul r11, r11, SWITCH_PERCENT
    xor ecx, ecx
scan:
    cmp rcx, top_tier
    ja scanned
    mov rax, [r8 + rcx*8]
    test rax, rax
    jz unchanged
    imul rax, rax, 100
    cmp rax, r11
    jae @F
    mov r11, rax
    mov r10, rcx
@@: inc rcx
    jmp scan
scanned:
    cmp r10, r9
    je unchanged
    inc switches
    mov current, r10
unchanged:
    mov trial, 0
    mov countdown, PROFILE_EVERY
    mov rax, current
    lea rdx, query_table
    mov rdx, [rdx + rax*8]
    lea rcx, site_query
    call patch_site
done:
    add rsp, 40
    ret
tier_tick ENDP

; tier_report() - print what the server chose and why
tier_report PROC FRAME
    push rbx
    .pushreg rbx
    sub rsp, 32
    .allocstack 32
    .endprolog
    PRINT "query tier       : "
    lea rax, tier_names
    mov rcx, current
    mov rcx, [rax + rcx*8]
    call print_str
    cmp adaptive, 0
    jne adaptive_line
    PRINT " (fixed)",13,10
    jmp done
adaptive_line:
    PRINT " (chosen live)",13,10
    PRINT "tier switches    : "
    mov rcx, switches
    call print_u64
    PRINT 13,10,"code patches     : "
    mov rcx, patches
    call print_u64
    PRINT 13,10,"cycles per query : scalar "
    mov rcx, [prof_cost]
    call print_u64
    PRINT ", AVX2 "
    mov rcx, [prof_cost + 8]
    call print_u64
    PRINT ", AVX-512 "
    mov rcx, [prof_cost + 16]
    call print_u64
    PRINT 13,10
done:
    add rsp, 32
    pop rbx
    ret
tier_report ENDP

END
