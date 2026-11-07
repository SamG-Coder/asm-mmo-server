; mmonet.asm - kernel driver for the MMO server. Milestone 1: no networking yet.
;
; This proves the foundation: the driver loads, creates \\.\MmoNet, answers one IOCTL
; and unloads cleanly. A later milestone adds the network filter and shared packet rings.
;
; The kernel structure offsets below are for x64 Windows. There are no WDK headers here,
; so they are stated explicitly. A wrong offset crashes the machine: VM only until proven.
OPTION CASEMAP:NONE

EXTERN IoCreateDevice:PROC
EXTERN IoDeleteDevice:PROC
EXTERN IoCreateSymbolicLink:PROC
EXTERN IoDeleteSymbolicLink:PROC
EXTERN IofCompleteRequest:PROC

; DRIVER_OBJECT
DRV_UNLOAD          equ 68h
DRV_MAJOR           equ 70h
IRP_MJ_CREATE       equ 0
IRP_MJ_CLOSE        equ 2
IRP_MJ_DEVICE_CONTROL equ 0Eh

; IRP
IRP_SYSTEM_BUFFER   equ 18h
IRP_STATUS          equ 30h
IRP_INFORMATION     equ 38h
IRP_STACK           equ 0B8h

; IO_STACK_LOCATION, Parameters.DeviceIoControl
STACK_OUT_LEN       equ 08h
STACK_IN_LEN        equ 10h
STACK_IOCTL         equ 18h

FILE_DEVICE_UNKNOWN equ 22h
FILE_DEVICE_SECURE_OPEN equ 100h

STATUS_SUCCESS      equ 0
STATUS_INVALID_DEVICE_REQUEST equ 0C0000010h
STATUS_BUFFER_TOO_SMALL equ 0C0000023h

; CTL_CODE(0x8000, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS). Input and output are one
; qword in a kernel-owned copy of the caller's buffer, so user pointers are never touched.
IOCTL_MMONET_PING   equ 80002000h
PING_MIX            equ 4D4D4F4E45543031h   ; "MMONET01": reply = request XOR this

.const
device_chars dw '\','D','e','v','i','c','e','\','M','m','o','N','e','t',0
link_chars   dw '\','D','o','s','D','e','v','i','c','e','s','\','M','m','o','N','e','t',0

.data
; UNICODE_STRING: length and capacity in bytes, padding, then the buffer pointer
device_name dw 28, 30
            dd 0
            dq device_chars
link_name   dw 36, 38
            dd 0
            dq link_chars
device_object dq 0

.code

; finish_irp(rcx = IRP*, edx = status, r8 = bytes returned) -> eax = status
finish_irp PROC FRAME
    push rbx
    .pushreg rbx
    sub rsp, 32
    .allocstack 32
    .endprolog
    mov ebx, edx
    mov dword ptr [rcx + IRP_STATUS], edx
    mov qword ptr [rcx + IRP_INFORMATION], r8
    xor edx, edx                        ; IO_NO_INCREMENT
    call IofCompleteRequest
    mov eax, ebx
    add rsp, 32
    pop rbx
    ret
finish_irp ENDP

; NTSTATUS dispatch_create_close(DEVICE_OBJECT*, IRP*)
dispatch_create_close PROC
    mov rcx, rdx
    xor edx, edx
    xor r8d, r8d
    jmp finish_irp
dispatch_create_close ENDP

; NTSTATUS dispatch_ioctl(DEVICE_OBJECT*, IRP*)
dispatch_ioctl PROC
    mov rcx, rdx
    mov rax, qword ptr [rcx + IRP_STACK]
    cmp dword ptr [rax + STACK_IOCTL], IOCTL_MMONET_PING
    jne unknown
    cmp dword ptr [rax + STACK_IN_LEN], 8
    jb too_small
    cmp dword ptr [rax + STACK_OUT_LEN], 8
    jb too_small
    mov rax, qword ptr [rcx + IRP_SYSTEM_BUFFER]
    mov rdx, PING_MIX
    xor qword ptr [rax], rdx
    xor edx, edx                        ; STATUS_SUCCESS
    mov r8d, 8
    jmp finish_irp
too_small:
    mov edx, STATUS_BUFFER_TOO_SMALL
    xor r8d, r8d
    jmp finish_irp
unknown:
    mov edx, STATUS_INVALID_DEVICE_REQUEST
    xor r8d, r8d
    jmp finish_irp
dispatch_ioctl ENDP

; void driver_unload(DRIVER_OBJECT*)
driver_unload PROC FRAME
    sub rsp, 40
    .allocstack 40
    .endprolog
    lea rcx, link_name
    call IoDeleteSymbolicLink
    mov rcx, device_object
    call IoDeleteDevice
    add rsp, 40
    ret
driver_unload ENDP

; NTSTATUS DriverEntry(DRIVER_OBJECT*, UNICODE_STRING*)
DriverEntry PROC FRAME
    push rbx
    .pushreg rbx
    push rsi
    .pushreg rsi
    sub rsp, 56
    .allocstack 56
    .endprolog
    mov rbx, rcx

    lea r8, device_object
    mov qword ptr [rsp + 48], r8
    mov dword ptr [rsp + 40], 0         ; not exclusive
    mov dword ptr [rsp + 32], FILE_DEVICE_SECURE_OPEN
    mov r9d, FILE_DEVICE_UNKNOWN
    lea r8, device_name
    xor edx, edx                        ; no device extension
    call IoCreateDevice
    test eax, eax
    js done

    lea rcx, link_name
    lea rdx, device_name
    call IoCreateSymbolicLink
    mov esi, eax
    test eax, eax
    jns link_ok
    mov rcx, device_object
    call IoDeleteDevice
    mov eax, esi
    jmp done

link_ok:
    ; Publish the handlers only once everything they rely on exists.
    lea rax, dispatch_create_close
    mov qword ptr [rbx + DRV_MAJOR + IRP_MJ_CREATE*8], rax
    mov qword ptr [rbx + DRV_MAJOR + IRP_MJ_CLOSE*8], rax
    lea rax, dispatch_ioctl
    mov qword ptr [rbx + DRV_MAJOR + IRP_MJ_DEVICE_CONTROL*8], rax
    lea rax, driver_unload
    mov qword ptr [rbx + DRV_UNLOAD], rax
    xor eax, eax
done:
    add rsp, 56
    pop rsi
    pop rbx
    ret
DriverEntry ENDP

END
