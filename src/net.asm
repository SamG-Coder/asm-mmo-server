; net.asm - UDP transport on Windows Registered I/O (RIO).
;
; One socket, request queue and pair of completion queues per worker, on port + worker
; index. Each worker owns a contiguous range of player slots, and a client sends to the
; port of the worker that owns its slot. No state is shared on the network path.
;
; Memory is registered once at startup and stays pinned, so the kernel never has to lock
; or copy per-request buffer descriptions. Requests are queued in user mode with
; RIO_MSG_DEFER and handed over in batches, so a tick makes a few syscalls rather than
; one per packet. Completions are polled: a worker only looks during its own phases.
include defs.inc

AF_INET         equ 2
SOCK_DGRAM      equ 2
IPPROTO_UDP     equ 17
SOL_SOCKET      equ 0FFFFh
SO_SNDBUF       equ 1001h
SO_RCVBUF       equ 1002h
SIO_UDP_CONNRESET equ 9800000Ch
SOCKET_BUFFER   equ 33554432
LOOPBACK        equ 0100007Fh           ; 127.0.0.1: no auth yet, so stay local

SIO_GET_EXTENSION_TABLE equ 0C8000024h
WSA_FLAG_REGISTERED_IO  equ 100h
RIO_MSG_DEFER       equ 2
RIO_MSG_COMMIT_ONLY equ 8
RIO_CORRUPT_CQ      equ 0FFFFFFFFh
RIO_INVALID_BUFFERID equ 0FFFFFFFFh

; RIORESULT fields
RESULT_SIZE     equ 24
RESULT_STATUS   equ 0
RESULT_BYTES    equ 4
RESULT_REQUEST  equ 16

RESULT_BATCH    equ 1024                ; completions fetched per dequeue
COMMIT_BATCH    equ 256                 ; deferred sends per syscall
MIN_RX_SLOTS    equ 1024
MIN_TX_SLOTS    equ 256
MAX_IO_SLOTS    equ 262144              ; per worker

RX_PAYLOAD      equ 128                 ; larger datagrams complete with an error
RX_SLOT         equ RX_PAYLOAD + 32     ; payload, then the sender's address
ADDR_LEN        equ 28                  ; sizeof(SOCKADDR_INET)
TX_SLOT         equ 640                 ; holds the largest snapshot sim_query can write

.const
; WSAID_MULTIPLE_RIO {8509E081-96DD-4005-B165-9E2EE8C79E3F}
rio_guid        dd 8509E081h
                dw 96DDh, 4005h
                db 0B1h, 65h, 9Eh, 2Eh, 0E8h, 0C7h, 9Eh, 3Fh

.data
; RIO_EXTENSION_FUNCTION_TABLE, filled in by Winsock
rio_table       dq 112                  ; cbSize
rio_Receive     dq 0
rio_ReceiveEx   dq 0
rio_Send        dq 0
rio_SendEx      dq 0
rio_CloseCQ     dq 0
rio_CreateCQ    dq 0
rio_CreateRQ    dq 0
rio_Dequeue     dq 0
rio_Deregister  dq 0
rio_Notify      dq 0
rio_Register    dq 0
rio_ResizeCQ    dq 0
rio_ResizeRQ    dq 0
addr_buffer     dq 0                    ; RIO buffer id of g_addr

.code

; net_fatal(rcx = message) - print the message and the Winsock error, then exit
net_fatal PROC                          ; reached from any depth: realign first
    and rsp, -16
    sub rsp, 32
    call print_str
    PRINT " (Winsock error "
    call WSAGetLastError
    mov ecx, eax
    call print_u64
    PRINT ")",13,10
    mov ecx, 1
    call ExitProcess
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

; net_startup() - initialise Winsock, load the RIO functions, register the address table
net_startup PROC FRAME
    push rbx
    .pushreg rbx
    sub rsp, 480                        ; args, then a 408-byte WSADATA
    .allocstack 480
    .endprolog
    mov ecx, 0202h
    lea rdx, [rsp + 72]
    call WSAStartup
    test eax, eax
    jz @F
    NET_FAIL "error: WSAStartup failed"
@@:
    ; The function table can only be requested through a RIO socket.
    mov ecx, AF_INET
    mov edx, SOCK_DGRAM
    mov r8d, IPPROTO_UDP
    xor r9d, r9d
    mov qword ptr [rsp + 32], 0
    mov dword ptr [rsp + 40], WSA_FLAG_REGISTERED_IO
    call WSASocketW
    cmp rax, -1
    jne @F
    NET_FAIL "error: could not create a Registered I/O socket"
@@: mov rbx, rax
    mov rcx, rax
    mov edx, SIO_GET_EXTENSION_TABLE
    lea r8, rio_guid
    mov r9d, 16
    lea rax, rio_table
    mov qword ptr [rsp + 32], rax
    mov qword ptr [rsp + 40], 112
    lea rax, [rsp + 72]                 ; bytes returned
    mov qword ptr [rsp + 48], rax
    mov qword ptr [rsp + 56], 0
    mov qword ptr [rsp + 64], 0
    call WSAIoctl
    test eax, eax
    jz @F
    NET_FAIL "error: Registered I/O is not available"
@@: mov rcx, rbx
    call closesocket

    ; Every player's address is in registered memory, as RIOSendEx requires.
    mov rcx, g_addr
    mov rdx, g_players
    add rdx, ARRAY_PAD
    shl rdx, ADDR_SHIFT
    call rio_Register
    mov ecx, RIO_INVALID_BUFFERID
    cmp rax, rcx
    jne @F
    NET_FAIL "error: could not register the address table"
@@: mov addr_buffer, rax
    add rsp, 480
    pop rbx
    ret
net_startup ENDP

; clamp_slots(rcx = wanted, rdx = minimum) -> rax
clamp_slots PROC
    mov rax, rcx
    cmp rax, rdx
    cmovb rax, rdx
    mov ecx, MAX_IO_SLOTS
    cmp rax, rcx
    cmova rax, rcx
    ret
clamp_slots ENDP

; net_post_recv(rcx = WORKER*, rdx = receive slot, r8 = RIO flags) -> eax = success
net_post_recv PROC FRAME
    sub rsp, 120
    .allocstack 120
    .endprolog
    mov rax, [rcx].WORKER.w_rxid
    mov [rsp + 72], rax                 ; RIO_BUF for the payload
    mov [rsp + 88], rax                 ; RIO_BUF for the sender's address
    imul r9, rdx, RX_SLOT
    mov dword ptr [rsp + 80], r9d
    mov dword ptr [rsp + 84], RX_PAYLOAD
    add r9d, RX_PAYLOAD
    mov dword ptr [rsp + 96], r9d
    mov dword ptr [rsp + 100], ADDR_LEN
    lea rax, [rsp + 88]
    mov qword ptr [rsp + 32], rax       ; remote address
    mov qword ptr [rsp + 40], 0         ; no control buffer
    mov qword ptr [rsp + 48], 0         ; no flags buffer
    mov qword ptr [rsp + 56], r8        ; flags
    mov qword ptr [rsp + 64], rdx       ; request context = receive slot
    mov rcx, [rcx].WORKER.w_rq
    lea rdx, [rsp + 72]
    mov r8d, 1
    xor r9d, r9d                        ; no local address
    call rio_ReceiveEx
    add rsp, 120
    ret
net_post_recv ENDP

; net_open(rcx = WORKER*) - create this worker's socket, queues and registered buffers
net_open PROC FRAME
    push rbx
    .pushreg rbx
    push r12
    .pushreg r12
    push r13
    .pushreg r13
    sub rsp, 112
    .allocstack 112
    .endprolog
    mov rbx, rcx

    mov ecx, AF_INET
    mov edx, SOCK_DGRAM
    mov r8d, IPPROTO_UDP
    xor r9d, r9d
    mov qword ptr [rsp + 32], 0
    mov dword ptr [rsp + 40], WSA_FLAG_REGISTERED_IO
    call WSASocketW
    cmp rax, -1
    jne @F
    NET_FAIL "error: could not create a Registered I/O socket"
@@: mov [rbx].WORKER.w_sock, rax

    ; Datagrams that arrive with no receive slot posted wait in the socket buffer.
    mov dword ptr [rsp + 72], SOCKET_BUFFER
    mov rcx, rax
    mov edx, SOL_SOCKET
    mov r8d, SO_RCVBUF
    lea r9, [rsp + 72]
    mov dword ptr [rsp + 32], 4
    call setsockopt
    mov rcx, [rbx].WORKER.w_sock
    mov edx, SOL_SOCKET
    mov r8d, SO_SNDBUF
    lea r9, [rsp + 72]
    mov dword ptr [rsp + 32], 4
    call setsockopt

    ; Stop an ICMP "port unreachable" from a vanished client using up a receive.
    mov dword ptr [rsp + 72], 0         ; input value
    mov rcx, [rbx].WORKER.w_sock
    mov edx, SIO_UDP_CONNRESET
    lea r8, [rsp + 72]
    mov r9d, 4
    mov qword ptr [rsp + 32], 0         ; no output buffer
    mov qword ptr [rsp + 40], 0
    lea rax, [rsp + 76]                 ; bytes returned
    mov qword ptr [rsp + 48], rax
    mov qword ptr [rsp + 56], 0         ; no overlapped
    mov qword ptr [rsp + 64], 0         ; no completion routine
    call WSAIoctl

    ; sockaddr_in, with the port in network byte order
    mov rax, g_port
    add rax, [rbx].WORKER.w_index
    xchg al, ah
    mov word ptr [rsp + 80], AF_INET
    mov word ptr [rsp + 82], ax
    mov dword ptr [rsp + 84], LOOPBACK
    mov qword ptr [rsp + 88], 0
    mov rcx, [rbx].WORKER.w_sock
    lea rdx, [rsp + 80]
    mov r8d, 16
    call bind
    test eax, eax
    jz @F
    NET_FAIL "error: could not bind UDP socket (is the port in use?)"
@@:
    ; Size the pools for two ticks of traffic per owned player.
    mov rax, [rbx].WORKER.w_last
    sub rax, [rbx].WORKER.w_first
    lea rcx, [rax + rax]
    mov edx, MIN_RX_SLOTS
    call clamp_slots
    mov r12, rax                        ; receive slots
    mov rax, [rbx].WORKER.w_last
    sub rax, [rbx].WORKER.w_first
    lea rcx, [rax + rax + 64]
    mov edx, MIN_TX_SLOTS
    call clamp_slots
    mov r13, rax                        ; send slots
    mov [rbx].WORKER.w_txtop, rax

    ; Receive memory
    imul rcx, r12, RX_SLOT
    call alloc_zeroed
    mov [rbx].WORKER.w_rxbuf, rax
    mov rcx, rax
    imul rdx, r12, RX_SLOT
    call rio_Register
    mov ecx, RIO_INVALID_BUFFERID
    cmp rax, rcx
    jne @F
    NET_FAIL "error: could not register receive memory"
@@: mov [rbx].WORKER.w_rxid, rax

    ; Send memory, plus a stack of free send slots
    imul rcx, r13, TX_SLOT
    call alloc_zeroed
    mov [rbx].WORKER.w_txbase, rax
    mov rcx, rax
    imul rdx, r13, TX_SLOT
    call rio_Register
    mov ecx, RIO_INVALID_BUFFERID
    cmp rax, rcx
    jne @F
    NET_FAIL "error: could not register send memory"
@@: mov [rbx].WORKER.w_txid, rax
    lea rcx, [r13*4]
    call alloc_zeroed
    mov [rbx].WORKER.w_txfree, rax
    xor ecx, ecx
@@: mov dword ptr [rax + rcx*4], ecx
    inc rcx
    cmp rcx, r13
    jb @B

    mov ecx, RESULT_BATCH * RESULT_SIZE
    call alloc_zeroed
    mov [rbx].WORKER.w_results, rax

    ; Polled completion queues, sized so they can never overflow
    mov ecx, r12d
    xor edx, edx
    call rio_CreateCQ
    test rax, rax
    jnz @F
    NET_FAIL "error: could not create receive completion queue"
@@: mov [rbx].WORKER.w_cqrx, rax
    mov ecx, r13d
    xor edx, edx
    call rio_CreateCQ
    test rax, rax
    jnz @F
    NET_FAIL "error: could not create send completion queue"
@@: mov [rbx].WORKER.w_cqtx, rax

    mov rcx, [rbx].WORKER.w_sock
    mov edx, r12d
    mov r8d, 1
    mov r9d, r13d
    mov qword ptr [rsp + 32], 1
    mov rax, [rbx].WORKER.w_cqrx
    mov qword ptr [rsp + 40], rax
    mov rax, [rbx].WORKER.w_cqtx
    mov qword ptr [rsp + 48], rax
    mov qword ptr [rsp + 56], 0
    call rio_CreateRQ
    test rax, rax
    jnz @F
    NET_FAIL "error: could not create request queue"
@@: mov [rbx].WORKER.w_rq, rax

    ; Post every receive slot.
    xor r13d, r13d
post:
    mov rcx, rbx
    mov rdx, r13
    mov r8d, RIO_MSG_DEFER
    call net_post_recv
    test eax, eax
    jnz @F
    NET_FAIL "error: could not post receive"
@@: inc r13
    cmp r13, r12
    jb post
    mov rcx, rbx
    call net_commit_rx

    add rsp, 112
    pop r13
    pop r12
    pop rbx
    ret
net_open ENDP

; net_commit_rx(rcx = WORKER*) - hand deferred receives to the kernel
net_commit_rx PROC FRAME
    push rbx
    .pushreg rbx
    sub rsp, 48
    .allocstack 48
    .endprolog
    mov rbx, rcx
    TRACE_COMMIT_BEGIN
    mov rcx, [rbx].WORKER.w_rq
    xor edx, edx
    xor r8d, r8d
    mov r9d, RIO_MSG_COMMIT_ONLY
    mov qword ptr [rsp + 32], 0
    call rio_Receive
    TRACE_COMMIT_END
    add rsp, 48
    pop rbx
    ret
net_commit_rx ENDP

; net_drain(rcx = WORKER*) - apply all completed receives, then repost their slots.
; Reposts are only committed at the end, so a packet flood is bounded by the number of
; receive slots and cannot stall the tick.
net_drain PROC FRAME
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
    push r14
    .pushreg r14
    sub rsp, 56
    .allocstack 56
    .endprolog
    mov rbx, rcx
    mov qword ptr [rsp + 32], 0         ; anything to commit?

fetch:
    mov rcx, [rbx].WORKER.w_cqrx
    mov rdx, [rbx].WORKER.w_results
    mov r8d, RESULT_BATCH
    call rio_Dequeue
    cmp eax, RIO_CORRUPT_CQ
    jne @F
    NET_FAIL "error: receive completion queue is corrupt"
@@: test eax, eax
    jz finished
    mov r12d, eax
    mov rsi, [rbx].WORKER.w_results
    mov qword ptr [rsp + 32], 1

result:
    mov r13, qword ptr [rsi + RESULT_REQUEST]
    imul r14, r13, RX_SLOT
    add r14, [rbx].WORKER.w_rxbuf
    mov rcx, rbx
    mov rdx, r14
    mov r8d, dword ptr [rsi + RESULT_BYTES]
    cmp dword ptr [rsi + RESULT_STATUS], 0
    je @F
    mov r8d, -1                         ; failed, e.g. a datagram larger than the slot
@@: lea r9, [r14 + RX_PAYLOAD]
    call input_apply
repost:
    mov rcx, rbx
    mov rdx, r13
    mov r8d, RIO_MSG_DEFER
    call net_post_recv
    test eax, eax
    jnz @F
    NET_FAIL "error: could not repost receive"
@@: add rsi, RESULT_SIZE
    dec r12d
    jnz result
    jmp fetch

finished:
    cmp qword ptr [rsp + 32], 0
    je @F
    mov rcx, rbx
    call net_commit_rx
@@: add rsp, 56
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
net_drain ENDP

; net_flush(rcx = WORKER*) - hand deferred sends to the kernel. This is where the
; packets actually go out, on the calling thread.
net_flush PROC FRAME
    push rbx
    .pushreg rbx
    sub rsp, 48
    .allocstack 48
    .endprolog
    mov rbx, rcx
    cmp [rbx].WORKER.w_txpending, 0
    je done
    mov [rbx].WORKER.w_txpending, 0
    TRACE_COMMIT_BEGIN
    mov rcx, [rbx].WORKER.w_rq
    xor edx, edx
    xor r8d, r8d
    mov r9d, RIO_MSG_COMMIT_ONLY
    mov qword ptr [rsp + 32], 0
    call rio_Send
    TRACE_COMMIT_END
done:
    add rsp, 48
    pop rbx
    ret
net_flush ENDP

; net_reclaim(rcx = WORKER*) - return the slots of completed sends to the free stack
net_reclaim PROC FRAME
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
fetch:
    mov rcx, [rbx].WORKER.w_cqtx
    mov rdx, [rbx].WORKER.w_results
    mov r8d, RESULT_BATCH
    call rio_Dequeue
    cmp eax, RIO_CORRUPT_CQ
    jne @F
    NET_FAIL "error: send completion queue is corrupt"
@@: test eax, eax
    jz done
    mov edi, eax
    mov rsi, [rbx].WORKER.w_results
    mov r8, [rbx].WORKER.w_txfree
    mov r9, [rbx].WORKER.w_txtop
result:
    mov rax, qword ptr [rsi + RESULT_REQUEST]
    mov dword ptr [r8 + r9*4], eax
    inc r9
    cmp dword ptr [rsi + RESULT_STATUS], 0
    je @F
    inc [rbx].WORKER.w_txfail
@@: add rsi, RESULT_SIZE
    dec edi
    jnz result
    mov [rbx].WORKER.w_txtop, r9
    jmp fetch
done:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
net_reclaim ENDP

; net_tx_acquire(rcx = WORKER*) -> rax = registered buffer to encode into, or 0.
;
; With no slot free the snapshot is dropped rather than stalling the tick: UDP clients
; already tolerate loss, and the next tick's snapshot supersedes this one.
net_tx_acquire PROC FRAME
    push rbx
    .pushreg rbx
    sub rsp, 32
    .allocstack 32
    .endprolog
    mov rbx, rcx
    cmp [rbx].WORKER.w_txtop, 0
    jne have_slot
    call net_flush
    mov rcx, rbx
    call net_reclaim
    cmp [rbx].WORKER.w_txtop, 0
    jne have_slot
    inc [rbx].WORKER.w_txfail
    xor eax, eax
    jmp done
have_slot:
    mov rax, [rbx].WORKER.w_txtop
    dec rax
    mov [rbx].WORKER.w_txtop, rax
    mov rcx, [rbx].WORKER.w_txfree
    mov eax, dword ptr [rcx + rax*4]
    mov [rbx].WORKER.w_txcur, rax
    imul rax, rax, TX_SLOT
    add rax, [rbx].WORKER.w_txbase
done:
    add rsp, 32
    pop rbx
    ret
net_tx_acquire ENDP

; net_send(rcx = WORKER*, rdx = player, r8 = datagram bytes)
; Queues the buffer from the last net_tx_acquire. No syscall unless a batch is full.
net_send PROC FRAME
    push rbx
    .pushreg rbx
    sub rsp, 112
    .allocstack 112
    .endprolog
    mov rbx, rcx
    mov r9, r8                          ; datagram bytes, kept for the statistics
    shl rdx, ADDR_SHIFT

    mov rax, [rbx].WORKER.w_txid
    mov [rsp + 72], rax                 ; RIO_BUF for the payload
    mov rax, [rbx].WORKER.w_txcur
    imul rax, rax, TX_SLOT
    mov dword ptr [rsp + 80], eax
    mov dword ptr [rsp + 84], r8d
    mov rax, addr_buffer
    mov [rsp + 88], rax                 ; RIO_BUF for the player's address
    mov dword ptr [rsp + 96], edx
    mov dword ptr [rsp + 100], ADDR_LEN

    add [rbx].WORKER.w_txbytes, r9
    inc [rbx].WORKER.w_txpkts

    lea rax, [rsp + 88]
    mov qword ptr [rsp + 32], rax       ; remote address
    mov qword ptr [rsp + 40], 0         ; no control buffer
    mov qword ptr [rsp + 48], 0         ; no flags buffer
    mov qword ptr [rsp + 56], RIO_MSG_DEFER
    mov rax, [rbx].WORKER.w_txcur
    mov qword ptr [rsp + 64], rax       ; request context = send slot
    mov rcx, [rbx].WORKER.w_rq
    lea rdx, [rsp + 72]
    mov r8d, 1
    xor r9d, r9d                        ; no local address
    call rio_SendEx
    test eax, eax
    jz refused

    mov rax, [rbx].WORKER.w_txpending
    inc rax
    mov [rbx].WORKER.w_txpending, rax
    cmp rax, COMMIT_BATCH
    jb done
    mov rcx, rbx
    call net_flush
    jmp done

refused:
    ; Never queued, so no completion will come: return the slot now.
    inc [rbx].WORKER.w_txfail
    dec [rbx].WORKER.w_txpkts
    mov rax, [rbx].WORKER.w_txtop
    mov rcx, [rbx].WORKER.w_txfree
    mov rdx, [rbx].WORKER.w_txcur
    mov dword ptr [rcx + rax*4], edx
    inc [rbx].WORKER.w_txtop
done:
    add rsp, 112
    pop rbx
    ret
net_send ENDP

END
