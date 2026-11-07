/* loadgen.c - UDP load generator for `mmoserver serve`. Test tool, not the server.
 *
 * Each server worker gets one thread on its own physical core, away from the server's
 * workers: it sends an input per bot per period to that worker's port, and reads snapshots the
 * rest of the time. Compare "input rate" with 100%: below it, this tool couldn't keep up and
 * the run didn't test the load it claims to.
 *
 *   usage: loadgen <bots> <players> <threads> <hz> <seconds> <port> [first cpu] [send every]
 *   <players> and <threads> must match the server, so slot ranges line up.
 */
#define _WIN32_WINNT 0x0A00
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma pack(push, 1)
typedef struct { uint32_t magic, player, seq; int16_t dx, dy; uint64_t time; } Input;
typedef struct { uint8_t magic, count; uint16_t tick, ack; uint32_t time; uint16_t x, y; } SnapHeader;
#pragma pack(pop)

#define INPUT_MAGIC 0x494F4D4Du
#define SNAP_MAGIC 0x53
#define WIDE_IDS 0x80
#define HIST 1000000

typedef struct { uint64_t start, send_end, drain_end, received; } Period;

typedef struct {
    int index, first, last, hz, seconds, port, cpu;
    SOCKET sock;
    uint64_t end;
    Period *trace;  /* optional, see LOADGEN_TRACE */
    int periods;
    uint64_t sent, send_fail, received, bad, entries, bytes;
    uint32_t *hist; /* round trip, 10 us bins */
} Thread;

static LARGE_INTEGER freq;
static uint64_t now(void) {
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return (uint64_t)t.QuadPart;
}

static void open_socket(Thread *t) {
    t->sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    int buf = 64 * 1024 * 1024;
    setsockopt(t->sock, SOL_SOCKET, SO_RCVBUF, (char *)&buf, sizeof buf);
    setsockopt(t->sock, SOL_SOCKET, SO_SNDBUF, (char *)&buf, sizeof buf);
    struct sockaddr_in to = {0};
    to.sin_family = AF_INET;
    to.sin_port = htons((u_short)(t->port + t->index));
    to.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    connect(t->sock, (struct sockaddr *)&to, sizeof to);
    u_long nonblocking = 1;
    ioctlsocket(t->sock, FIONBIO, &nonblocking);
    DWORD off = 0, ret;
    WSAIoctl(t->sock, 0x9800000C, &off, sizeof off, NULL, 0, &ret, NULL, NULL);
}

/* One thread per server worker: send a burst of inputs, then read snapshots until the next
   period. Separate send and receive threads on SMT siblings were tried and kept up worse.
   Only the measured window counts: the server keeps sending after that, so counting a tail
   would push delivery past 100% and hide real losses. */
static DWORD WINAPI run(void *arg) {
    Thread *t = arg;
    SetThreadAffinityMask(GetCurrentThread(), 1ull << t->cpu);
    uint64_t period = (uint64_t)freq.QuadPart / t->hz;
    uint64_t next = now();
    uint32_t seq = 0, rng = 0x12345u + t->index;
    char rx[2048];

    while (now() < t->end) {
        seq++;
        Period *rec = t->trace && t->periods < t->hz * t->seconds + 8 ? &t->trace[t->periods++] : NULL;
        uint64_t before = t->received;
        if (rec) rec->start = now();
        for (int id = t->first; id < t->last; id++) {
            rng = rng * 1664525u + 1013904223u;
            Input in = {INPUT_MAGIC, (uint32_t)id, seq,
                        (int16_t)((int)(rng >> 16 & 2047) - 1000),
                        (int16_t)((int)(rng & 2047) - 1000), now()};
            if (send(t->sock, (char *)&in, sizeof in, 0) == sizeof in) t->sent++;
            else t->send_fail++;
        }
        if (rec) rec->send_end = now();
        next += period;
        for (;;) {
            int n = recv(t->sock, rx, sizeof rx, 0);
            if (n < 0) {
                if (now() >= next) break;
                SwitchToThread();
                continue;
            }
            SnapHeader *h = (SnapHeader *)rx;
            int count = h->count & ~WIDE_IDS, width = h->count & WIDE_IDS ? 6 : 5;
            if (n < (int)sizeof *h || h->magic != SNAP_MAGIC || n != (int)sizeof *h + count * width) {
                t->bad++;
                continue;
            }
            t->received++;
            t->entries += (uint64_t)count;
            t->bytes += (uint64_t)n;
            uint64_t us = (uint32_t)((uint32_t)now() - h->time) * 100000ull / (uint64_t)freq.QuadPart;
            t->hist[us < HIST ? us : HIST - 1]++;
        }
        if (rec) {
            rec->drain_end = now();
            rec->received = t->received - before;
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 7) {
        puts("usage: loadgen <bots> <players> <threads> <hz> <seconds> <port>");
        return 1;
    }
    int bots = atoi(argv[1]), players = (atoi(argv[2]) + 7) & ~7, threads = atoi(argv[3]);
    int hz = atoi(argv[4]), seconds = atoi(argv[5]), port = atoi(argv[6]);
    if (bots > players) bots = players;
    /* Logical CPU for thread 0; later threads step down one physical core, wrapping. The
       default of 0 gives 0, 14, 12, 10 on 16 CPUs, clear of the server's 2, 4, 6, 8. */
    int first_cpu = argc > 7 ? atoi(argv[7]) : 0;
    /* The server sends each player a snapshot every this many ticks. */
    int every = argc > 8 ? atoi(argv[8]) : 1;

    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    QueryPerformanceFrequency(&freq);
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    int cpus = (int)si.dwNumberOfProcessors;

    /* Same slot division as the server's setup. */
    int per = ((players + threads - 1) / threads + 7) & ~7;

    Thread *t = calloc(threads, sizeof(Thread));
    HANDLE *h = calloc(threads, sizeof(HANDLE));
    uint64_t end = now() + (uint64_t)freq.QuadPart * seconds;
    for (int i = 0; i < threads; i++) {
        int first = i * per, last = first + per;
        t[i].index = i;
        t[i].first = first < bots ? first : bots;
        t[i].last = last < bots ? last : bots;
        t[i].hz = hz;
        t[i].seconds = seconds;
        t[i].port = port;
        t[i].cpu = (first_cpu - 2 * i + 2 * cpus) % cpus;
        if (getenv("LOADGEN_TRACE")) t[i].trace = calloc(hz * seconds + 8, sizeof(Period));
        t[i].end = end;
        t[i].hist = calloc(HIST, sizeof(uint32_t));
        open_socket(&t[i]);
        h[i] = CreateThread(NULL, 0, run, &t[i], 0, NULL);
    }
    WaitForMultipleObjects(threads, h, TRUE, INFINITE);

    if (getenv("LOADGEN_TRACE")) {
        FILE *f = fopen(getenv("LOADGEN_TRACE"), "w");
        fprintf(f, "thread,period,start,send_end,drain_end,received\n");
        for (int i = 0; f && i < threads; i++)
            for (int p = 0; p < t[i].periods; p++)
                fprintf(f, "%d,%d,%llu,%llu,%llu,%llu\n", i, p, t[i].trace[p].start,
                        t[i].trace[p].send_end, t[i].trace[p].drain_end, t[i].trace[p].received);
        if (f) fclose(f);
    }

    uint64_t sent = 0, recvd = 0, bad = 0, fail = 0, entries = 0, bytes = 0, samples = 0;
    uint32_t *all = calloc(HIST, sizeof(uint32_t));
    for (int i = 0; i < threads; i++) {
        sent += t[i].sent;
        recvd += t[i].received;
        bad += t[i].bad;
        fail += t[i].send_fail;
        entries += t[i].entries;
        bytes += t[i].bytes;
        for (int b = 0; b < HIST; b++) {
            all[b] += t[i].hist[b];
            samples += t[i].hist[b];
        }
    }
    uint64_t p50 = 0, p99 = 0, seen = 0;
    for (int b = 0; b < HIST; b++) {
        if (seen < samples / 2 && seen + all[b] >= samples / 2) p50 = b * 10ull;
        if (seen < samples * 99 / 100 && seen + all[b] >= samples * 99 / 100) p99 = b * 10ull;
        seen += all[b];
    }
    printf("bots             : %d\n", bots);
    printf("inputs sent      : %llu (%llu/s), %llu failed\n", sent, sent / seconds, fail);
    printf("snapshots recv   : %llu (%llu/s), %llu malformed\n", recvd, recvd / seconds, bad);
    printf("input rate       : %.1f%%\n", 100.0 * sent / ((double)bots * hz * seconds));
    printf("expected snaps   : %llu\n", (uint64_t)bots * hz * seconds / every);
    printf("delivery         : %.2f%%\n", 100.0 * recvd * every / ((double)bots * hz * seconds));
    printf("bandwidth        : %.1f MB/s\n", (double)bytes / seconds / 1e6);
    printf("avg entries/snap : %llu\n", samples ? entries / samples : 0);
    printf("round trip p50   : %llu us\n", p50);
    printf("round trip p99   : %llu us\n", p99);
    return 0;
}
