; drvtest.asm - user-mode check of the loaded driver. Run inside the VM after installing.
; Exit status 0 means: the device opened, ping replied correctly, bad requests were refused.
OPTION CASEMAP:NONE

EXTERN ExitProcess:PROC
EXTERN GetStdHandle:PROC
EXTERN WriteFile:PROC
EXTERN CreateFileA:PROC
EXTERN DeviceIoControl:PROC
EXTERN CloseHandle:PROC

IOCTL_MMONET_PING   equ 80002000h
IOCTL_UNKNOWN       equ 80002004h
PING_MIX            equ 4D4D4F4E45543031h
PING_VALUE          equ 0123456789ABCDEFh

.const
device_path db "\\.\MmoNet", 0
msg_noopen  db "FAIL could not open \\.\MmoNet (is the driver started?)", 13, 10, 0
msg_open    db "ok   device opened", 13, 10, 0
msg_ping    db "ok   ping reply is correct", 13, 10, 0
msg_badping db "FAIL ping reply is wrong", 13, 10, 0
msg_short   db "ok   too-small buffer refused", 13, 10, 0
msg_badshort db "FAIL too-small buffer was accepted", 13, 10, 0
msg_unknown db "ok   unknown request refused", 13, 10, 0
msg_badunknown db "FAIL unknown request was accepted", 13, 10, 0
msg_done    db "all driver checks passed", 13, 10, 0

.code

print PROC FRAME
    push rbx
    .pushreg rbx
    sub rsp, 48
    .allocstack 48
    .endprolog
    mov rbx, rcx
    mov ecx, -11
    call GetStdHandle
    mov rcx, rax
    mov rdx, rbx
    xor r8d, r8d
@@: cmp byte ptr [rdx + r8], 0
    je @F
    inc r8
    jmp @B
@@: lea r9, [rsp + 40]
    mov qword ptr [rsp + 32], 0
    call WriteFile
    add rsp, 48
    pop rbx
    ret
print ENDP

; ioctl(rcx = handle, edx = code, r8 = in/out buffer, r9d = in and out size) -> eax = success
ioctl PROC FRAME
    sub rsp, 72
    .allocstack 72
    .endprolog
    mov qword ptr [rsp + 32], r8        ; out buffer
    mov dword ptr [rsp + 40], r9d       ; out size
    lea rax, [rsp + 64]
    mov qword ptr [rsp + 48], rax       ; bytes returned
    mov qword ptr [rsp + 56], 0         ; no overlapped
    call DeviceIoControl
    add rsp, 72
    ret
ioctl ENDP

fail PROC                               ; rcx = message; reached by jmp
    and rsp, -16
    sub rsp, 32
    call print
    mov ecx, 1
    call ExitProcess
    int 3
fail ENDP

start PROC FRAME
    push rbx
    .pushreg rbx
    sub rsp, 80
    .allocstack 80
    .endprolog

    lea rcx, device_path
    mov edx, 0C0000000h                 ; GENERIC_READ | GENERIC_WRITE
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 3         ; OPEN_EXISTING
    mov qword ptr [rsp + 40], 0
    mov qword ptr [rsp + 48], 0
    call CreateFileA
    lea rcx, msg_noopen
    cmp rax, -1
    je fail
    mov rbx, rax
    lea rcx, msg_open
    call print

    ; A correct reply proves the request reached our handler and the buffer offset is right.
    mov rax, PING_VALUE
    mov qword ptr [rsp + 64], rax
    mov rcx, rbx
    mov edx, IOCTL_MMONET_PING
    lea r8, [rsp + 64]
    mov r9d, 8
    call ioctl
    lea rcx, msg_badping
    test eax, eax
    jz fail
    mov rax, PING_VALUE
    mov rdx, PING_MIX
    xor rax, rdx
    cmp qword ptr [rsp + 64], rax
    lea rcx, msg_badping
    jne fail
    lea rcx, msg_ping
    call print

    mov rcx, rbx
    mov edx, IOCTL_MMONET_PING
    lea r8, [rsp + 64]
    mov r9d, 4
    call ioctl
    lea rcx, msg_badshort
    test eax, eax
    jnz fail
    lea rcx, msg_short
    call print

    mov rcx, rbx
    mov edx, IOCTL_UNKNOWN
    lea r8, [rsp + 64]
    mov r9d, 8
    call ioctl
    lea rcx, msg_badunknown
    test eax, eax
    jnz fail
    lea rcx, msg_unknown
    call print

    mov rcx, rbx
    call CloseHandle
    lea rcx, msg_done
    call print
    xor ecx, ecx
    call ExitProcess
    int 3
start ENDP

END
