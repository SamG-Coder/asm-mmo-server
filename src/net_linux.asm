; net_linux.asm - UDP transport on Linux, using recvmmsg and sendmmsg.
;
; One socket per worker, on port + worker index, like net.asm. Datagrams are batched into a
; single system call each way. These batches still pass through the kernel's network stack:
; io_uring and AF_XDP would be later steps.
;
; WORKER fields reused here: w_rxbuf = receive memory, w_results = receive mmsghdr array,
; w_txbase = send memory, w_txfree = send mmsghdr array, w_txpending = queued sends.
include defs.inc

SYS_SOCKET      equ 41
SYS_BIND        equ 49
SYS_SETSOCKOPT  equ 54
SYS_GETSOCKOPT  equ 55
SYS_RECVMMSG    equ 299
SYS_SENDMMSG    equ 307

AF_INET         equ 2
SOCK_DGRAM_NONBLOCK equ 802h            ; SOCK_DGRAM | SOCK_NONBLOCK
IPPROTO_UDP     equ 17
SOL_SOCKET      equ 1
SO_RCVBUF       equ 8
SO_SNDBUF       equ 7
SO_RCVBUFFORCE  equ 33
SO_SNDBUFFORCE  equ 32
SOCKET_BUFFER   equ 33554432
LOOPBACK        equ 0100007Fh           ; 127.0.0.1: no auth yet, so stay local
MSG_DONTWAIT    equ 40h
MSG_TRUNC       equ 20h

; struct mmsghdr
MSG_SIZE        equ 64
MSG_NAME        equ 0
MSG_NAMELEN     equ 8
MSG_IOV         equ 16
MSG_IOVLEN      equ 24
MSG_FLAGS       equ 48
MSG_LEN         equ 56
IOV_SIZE        equ 16

RX_BATCH        equ 1024
RX_PAYLOAD      equ 128                 ; larger datagrams arrive truncated, and are rejected
RX_SLOT         equ RX_PAYLOAD + 32     ; payload, then the sender's address
SENDER_ROOM     equ 32
TX_BATCH        equ 256
TX_SLOT         equ 640                 ; holds the largest snapshot a query can write

.code

; net_startup() - nothing to prepare on Linux
net_startup PROC
    ret
net_startup ENDP

; net_fatal(rcx = message, rax = negative errno) - reached by jmp
net_fatal PROC
    mov rbx, rax
    neg rbx
    and rsp, -16
    sub rsp, 32
    call print_str
    PRINT " (errno "
    mov rcx, rbx
    call print_u64
    PRINT ")",13,10
    mov ecx, 1
    call os_exit
    int 3
net_fatal ENDP

NET_FAIL MACRO text:VARARG
    LOCAL lbl
    .const
lbl db text, 0
    .code
    lea rcx, lbl
    jmp net_fatal
ENDM

; set_buffer(rcx = socket, edx = privileged option, r8d = fallback option)
; The privileged option may exceed net.core.*mem_max but needs CAP_NET_ADMIN.
set_buffer PROC
    push rsi
    push rdi
    push r12
    sub rsp, 16
    mov dword ptr [rsp], SOCKET_BUFFER
    mov r12d, r8d
    mov rdi, rcx
    mov esi, SOL_SOCKET
    lea r10, [rsp]
    mov r8d, 4
    mov eax, SYS_SETSOCKOPT
    push rdi
    syscall
    pop rdi
    test rax, rax
    jz done
    mov esi, SOL_SOCKET
    mov edx, r12d
    lea r10, [rsp]
    mov r8d, 4
    mov eax, SYS_SETSOCKOPT
    syscall
done:
    add rsp, 16
    pop r12
    pop rdi
    pop rsi
    ret
set_buffer ENDP

; net_open(rcx = WORKER*) - create this worker's socket and batches
net_open PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 64
    mov rbx, rcx

    mov edi, AF_INET
    mov esi, SOCK_DGRAM_NONBLOCK
    mov edx, IPPROTO_UDP
    mov eax, SYS_SOCKET
    syscall
    test rax, rax
    jns @F
    NET_FAIL "error: could not create UDP socket"
@@: mov [rbx].WORKER.w_sock, rax

    mov rcx, rax
    mov edx, SO_RCVBUFFORCE
    mov r8d, SO_RCVBUF
    call set_buffer
    mov rcx, [rbx].WORKER.w_sock
    mov edx, SO_SNDBUFFORCE
    mov r8d, SO_SNDBUF
    call set_buffer

    ; Inputs queue here between ticks, so a small buffer silently loses them.
    cmp [rbx].WORKER.w_index, 0
    jne buffer_checked
    mov rdi, [rbx].WORKER.w_sock
    mov esi, SOL_SOCKET
    mov edx, SO_RCVBUF
    lea r10, [rsp + 32]
    lea r8, [rsp + 40]
    mov dword ptr [rsp + 40], 4
    mov eax, SYS_GETSOCKOPT
    syscall
    test rax, rax
    jnz buffer_checked
    cmp dword ptr [rsp + 32], SOCKET_BUFFER
    jae buffer_checked
    PRINT "warning: socket receive buffer is limited, so inputs may be lost. Raise it with: sysctl -w net.core.rmem_max=67108864 net.core.wmem_max=67108864",13,10
buffer_checked:

    ; sockaddr_in, with the port in network byte order
    mov rax, g_port
    add rax, [rbx].WORKER.w_index
    xchg al, ah
    mov word ptr [rsp + 48], AF_INET
    mov word ptr [rsp + 50], ax
    mov dword ptr [rsp + 52], LOOPBACK
    mov qword ptr [rsp + 56], 0
    mov rdi, [rbx].WORKER.w_sock
    lea rsi, [rsp + 48]
    mov edx, 16
    mov eax, SYS_BIND
    syscall
    test rax, rax
    jz @F
    NET_FAIL "error: could not bind UDP socket (is the port in use?)"
@@:
    ; Receive batch: each slot's name, payload and iovec are fixed.
    mov ecx, RX_BATCH * (RX_SLOT + MSG_SIZE + IOV_SIZE)
    call alloc_zeroed
    mov [rbx].WORKER.w_rxbuf, rax
    mov r8, rax                         ; payload slots
    lea r9, [rax + RX_BATCH * RX_SLOT]  ; mmsghdr array
    mov [rbx].WORKER.w_results, r9
    lea r10, [r9 + RX_BATCH * MSG_SIZE] ; iovec array
    xor ecx, ecx
rx_slots:
    lea rax, [r8 + RX_PAYLOAD]
    mov [r9 + MSG_NAME], rax
    mov [r9 + MSG_IOV], r10
    mov qword ptr [r9 + MSG_IOVLEN], 1
    mov [r10], r8
    mov qword ptr [r10 + 8], RX_PAYLOAD
    add r8, RX_SLOT
    add r9, MSG_SIZE
    add r10, IOV_SIZE
    inc ecx
    cmp ecx, RX_BATCH
    jb rx_slots

    ; Send batch: each slot's payload and iovec are fixed; address and length vary.
    mov ecx, TX_BATCH * (TX_SLOT + MSG_SIZE + IOV_SIZE)
    call alloc_zeroed
    mov [rbx].WORKER.w_txbase, rax
    mov r8, rax
    lea r9, [rax + TX_BATCH * TX_SLOT]
    mov [rbx].WORKER.w_txfree, r9
    lea r10, [r9 + TX_BATCH * MSG_SIZE]
    xor ecx, ecx
tx_slots:
    mov dword ptr [r9 + MSG_NAMELEN], 16
    mov [r9 + MSG_IOV], r10
    mov qword ptr [r9 + MSG_IOVLEN], 1
    mov [r10], r8
    add r8, TX_SLOT
    add r9, MSG_SIZE
    add r10, IOV_SIZE
    inc ecx
    cmp ecx, TX_BATCH
    jb tx_slots

    add rsp, 64
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
net_open ENDP

; net_drain(rcx = WORKER*) - apply all queued inputs. Bounded, so that a packet flood cannot
; stall the tick.
net_drain PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rbx, rcx
    mov r12, [rbx].WORKER.w_last
    sub r12, [rbx].WORKER.w_first
    lea r12, [r12*4 + RX_BATCH]         ; datagrams allowed this tick
fetch:
    ; The kernel overwrites each name length, so reset them.
    mov rax, [rbx].WORKER.w_results
    mov ecx, RX_BATCH
@@: mov dword ptr [rax + MSG_NAMELEN], SENDER_ROOM
    add rax, MSG_SIZE
    dec ecx
    jnz @B

    mov rdi, [rbx].WORKER.w_sock
    mov rsi, [rbx].WORKER.w_results
    mov edx, RX_BATCH
    mov r10d, MSG_DONTWAIT
    xor r8d, r8d
    mov eax, SYS_RECVMMSG
    syscall
    test rax, rax
    jle done                            ; EAGAIN: the queue is empty
    mov r13, rax
    mov r14, rsi                        ; mmsghdr
    mov r15, [rbx].WORKER.w_rxbuf
    sub r12, rax
result:
    mov rcx, rbx
    mov rdx, r15
    mov r8d, dword ptr [r14 + MSG_LEN]
    test dword ptr [r14 + MSG_FLAGS], MSG_TRUNC
    jz @F
    mov r8d, -1
@@: lea r9, [r15 + RX_PAYLOAD]
    call input_apply
    add r14, MSG_SIZE
    add r15, RX_SLOT
    dec r13
    jnz result
    test r12, r12
    jg fetch
done:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
net_drain ENDP

; net_reclaim(rcx = WORKER*) - sendmmsg is synchronous, so there is nothing to reclaim
net_reclaim PROC
    ret
net_reclaim ENDP

; net_flush(rcx = WORKER*) - send everything queued. Whatever the socket refuses is dropped
; and counted: UDP clients tolerate loss, and the next snapshot supersedes it.
net_flush PROC
    push rbx
    push rsi
    push rdi
    push r12
    mov rbx, rcx
    mov r12, [rbx].WORKER.w_txpending
    mov rsi, [rbx].WORKER.w_txfree
next:
    test r12, r12
    jz done
    mov rdi, [rbx].WORKER.w_sock
    mov rdx, r12
    xor r10d, r10d
    mov eax, SYS_SENDMMSG
    syscall
    test rax, rax
    jle refused
    sub r12, rax
    imul rax, rax, MSG_SIZE
    add rsi, rax
    jmp next
refused:
    add [rbx].WORKER.w_txfail, r12
    sub [rbx].WORKER.w_txpkts, r12
done:
    mov [rbx].WORKER.w_txpending, 0
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
net_flush ENDP

; net_tx_acquire(rcx = WORKER*) -> rax = buffer to encode the next snapshot into
net_tx_acquire PROC
    push rbx
    sub rsp, 32
    mov rbx, rcx
    cmp [rbx].WORKER.w_txpending, TX_BATCH
    jb @F
    call net_flush
@@: imul rax, [rbx].WORKER.w_txpending, TX_SLOT
    add rax, [rbx].WORKER.w_txbase
    add rsp, 32
    pop rbx
    ret
net_tx_acquire ENDP

; net_send(rcx = WORKER*, rdx = player, r8 = datagram bytes)
; Queues the buffer from the last net_tx_acquire. net_flush sends it.
net_send PROC
    imul rax, [rcx].WORKER.w_txpending, MSG_SIZE
    add rax, [rcx].WORKER.w_txfree
    shl rdx, ADDR_SHIFT
    add rdx, g_addr
    mov [rax + MSG_NAME], rdx
    mov r9, [rax + MSG_IOV]
    mov [r9 + 8], r8
    add [rcx].WORKER.w_txbytes, r8
    inc [rcx].WORKER.w_txpkts
    inc [rcx].WORKER.w_txpending
    ret
net_send ENDP

END
