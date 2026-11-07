/* test_sim.c - checks the real assembly kernels (sim.obj) against brute force.
 *
 * Exact expected results are computed the slow way for every player, across worlds
 * chosen to hit the edge cases: an empty border, one-cell grids, heavy capping, and
 * player counts that end mid-way through a SIMD block.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#define KERNEL
#else
#include <sys/mman.h>
/* The kernels take arguments in rcx and rdx on every system. */
#define KERNEL __attribute__((ms_abi))
#endif

#define MAX_VISIBLE 64
#define PAD 64

/* The globals sim.asm reads. Names and types must match src/defs.inc. */
uint64_t g_players, g_gw, g_stride, g_ncells;
float g_dt, g_worldmax, g_r2, g_inv, g_quant, g_relscale;
uint64_t g_entsize;
float *g_px, *g_py, *g_vx, *g_vy, *g_sx, *g_sy;
uint32_t *g_cell, *g_start, *g_id;

extern KERNEL void integrate_scalar(uint64_t first, uint64_t last);
extern KERNEL void integrate_avx2(uint64_t first, uint64_t last);
extern KERNEL void cells_scalar(void);
extern KERNEL void cells_avx2(void);
extern KERNEL uint64_t query_scalar(uint64_t slot, uint8_t *out);
extern KERNEL uint64_t query_avx2(uint64_t slot, uint8_t *out);
extern KERNEL uint64_t query_avx512(uint64_t slot, uint8_t *out);
extern KERNEL void sim_grid_build(void);

/* The test picks the kernels directly. In the server, tier.asm patches these sites. */
static int tier;
KERNEL void site_cells(void) { if (tier) cells_avx2(); else cells_scalar(); }
static void sim_integrate(uint64_t first, uint64_t last) {
    if (tier) integrate_avx2(first, last); else integrate_scalar(first, last);
}
static uint64_t sim_query(uint64_t slot, uint8_t *out) {
    return tier == 2 ? query_avx512(slot, out) : tier == 1 ? query_avx2(slot, out) : query_scalar(slot, out);
}

static uint64_t rng = 0x123456789ABCDEFull;
static float randf(void) {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return (float)((rng * 0x2545F4914F6CDD1Dull) >> 32) * 2.3283064365386963e-10f;
}

static void *zalloc(size_t n) {
#ifdef _WIN32
    return VirtualAlloc(NULL, n, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
#else
    return mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
#endif
}

static int failures;
#define CHECK(cond, ...)                 \
    do {                                 \
        if (!(cond)) {                   \
            if (failures++ < 10) {       \
                printf("  FAIL: ");      \
                printf(__VA_ARGS__);     \
                printf("\n");            \
            }                            \
        }                                \
    } while (0)

static void run(int n, int world, int radius, int entsize) {
    int before = failures;
    float w = (float)world;
    union { float f; uint32_t u; } m = {w};
    m.u--;
    g_players = (uint64_t)n;
    g_dt = 1.0f / 30.0f;
    g_worldmax = m.f;
    g_r2 = (float)radius * (float)radius;
    g_gw = (uint64_t)(world / radius);
    if (g_gw > 4096) g_gw = 4096;
    g_inv = (float)g_gw / w;
    g_quant = 65535.0f / w;
    g_relscale = 2047.0f / (float)radius;
    g_entsize = (uint64_t)entsize;
    g_stride = g_gw + 2;
    g_ncells = g_stride * g_stride;

    size_t cnt = (size_t)n + PAD;
    g_px = zalloc(cnt * 4); g_py = zalloc(cnt * 4);
    g_vx = zalloc(cnt * 4); g_vy = zalloc(cnt * 4);
    g_sx = zalloc(cnt * 4); g_sy = zalloc(cnt * 4);
    g_cell = zalloc(cnt * 4);
    g_id = zalloc(cnt * 4);
    g_start = zalloc((g_ncells + 3 + PAD) * 4);
    uint8_t *out = zalloc(65536);
    uint8_t *seen = zalloc(cnt);

    for (int i = 0; i < n; i++) {
        g_px[i] = randf() * w;
        g_py[i] = randf() * w;
        g_vx[i] = randf() * 16.0f - 8.0f;
        g_vy[i] = randf() * 16.0f - 8.0f;
    }

    uint64_t total = 0, capped = 0;
    for (int tick = 0; tick < 5; tick++) {
        /* Integration against a scalar model of the same rule. */
        float *ex = malloc(cnt * 4), *ey = malloc(cnt * 4);
        float *evx = malloc(cnt * 4), *evy = malloc(cnt * 4);
        for (int i = 0; i < n; i++) {
            float x = g_px[i] + g_vx[i] * g_dt, y = g_py[i] + g_vy[i] * g_dt;
            float cx = x < 0 ? 0 : (x > g_worldmax ? g_worldmax : x);
            float cy = y < 0 ? 0 : (y > g_worldmax ? g_worldmax : y);
            ex[i] = cx; ey[i] = cy;
            evx[i] = cx != x ? -g_vx[i] : g_vx[i];
            evy[i] = cy != y ? -g_vy[i] : g_vy[i];
        }
        sim_integrate(0, (uint64_t)n);
        for (int i = 0; i < n; i++) {
            /* FMA rounds once and the model twice, so allow tiny differences. */
            float dx = g_px[i] - ex[i], dy = g_py[i] - ey[i];
            CHECK(dx > -1e-2f && dx < 1e-2f && dy > -1e-2f && dy < 1e-2f, "position of %d", i);
            CHECK(g_px[i] >= 0 && g_px[i] < w && g_py[i] >= 0 && g_py[i] < w, "%d left the world", i);
            CHECK(abs((int)(g_vx[i] * 1000)) == abs((int)(evx[i] * 1000)), "vx of %d", i);
        }
        free(ex); free(ey); free(evx); free(evy);

        sim_grid_build();

        /* The sort must be a permutation, with all cell ranges consistent. */
        memset(seen, 0, cnt);
        for (int j = 0; j < n; j++) {
            uint32_t id = g_id[j];
            CHECK(id < (uint32_t)n && !seen[id], "sorted entity %d duplicated", j);
            if (id < (uint32_t)n) {
                seen[id] = 1;
                CHECK(g_sx[j] == g_px[id] && g_sy[j] == g_py[id], "sorted position %d", j);
            }
        }
        for (uint64_t c = 0; c < g_ncells; c++)
            CHECK(g_start[c] <= g_start[c + 1], "start not monotonic at %llu", c);
        CHECK(g_start[g_ncells] == (uint32_t)n, "start end %u", g_start[g_ncells]);

        /* Each query against brute force. */
        for (int i = 0; i < n; i++) {
            int expect = 0;
            memset(seen, 0, cnt);
            for (int j = 0; j < n; j++) {
                float dx = g_px[j] - g_px[i], dy = g_py[j] - g_py[i];
                if (dx * dx + dy * dy <= g_r2) { seen[j] = 1; expect++; }
            }
            uint64_t got = sim_query((uint64_t)i, out);
            total += got;
            if (expect <= MAX_VISIBLE) {
                CHECK(got == (uint64_t)expect, "player %d: got %llu, expected %d", i, got, expect);
            } else {
                capped++;
                CHECK(got >= MAX_VISIBLE && got < MAX_VISIBLE + 16, "player %d: capped got %llu", i, got);
            }
            for (uint64_t k = 0; k < got && k < MAX_VISIBLE + 16; k++) {
                uint64_t e;
                memcpy(&e, out + k * g_entsize, 8);
                uint32_t rx = (uint32_t)(e & 0xFFF), ry = (uint32_t)(e >> 12 & 0xFFF);
                uint32_t id = (uint32_t)(e >> 24) & (entsize == 5 ? 0xFFFFu : 0xFFFFFFu);
                CHECK(id < (uint32_t)n && seen[id] == 1, "player %d: entity %u should not be visible", i, id);
                if (id < (uint32_t)n) {
                    seen[id] = 2; /* a second report trips the check above */
                    /* The decoded position must match the true one to within one step. */
                    int ex = (int)((g_px[id] - g_px[i]) * g_relscale + 2048.5f);
                    int ey = (int)((g_py[id] - g_py[i]) * g_relscale + 2048.5f);
                    CHECK(abs((int)rx - ex) <= 1 && abs((int)ry - ey) <= 1,
                          "player %d: entity %u encoded at %u,%u, expected %d,%d", i, id, rx, ry, ex, ey);
                    if (id == (uint32_t)i)
                        CHECK(rx == 2048 && ry == 2048, "player %d: own entry is not centred", i);
                }
            }
        }
    }

    printf("%s tier=%d n=%-6d world=%-6d radius=%-4d grid=%-5llu entry=%d bytes avg_visible=%-5llu capped=%llu\n",
           failures == before ? "ok  " : "FAIL", tier, n, world, radius, g_gw, entsize,
           total / ((uint64_t)n * 5), capped);
}

int main(void) {
    /* {players, world, radius}. Players are always multiples of 8, as in the server. */
    __builtin_cpu_init();
    int top = __builtin_cpu_supports("avx512f") ? 2 : __builtin_cpu_supports("avx2") ? 1 : 0;
    for (tier = 0; tier <= top; tier++) {
    run(8, 100, 50, 5);        /* smallest world, a tiny grid */
    run(16, 1000, 1000, 5);    /* one cell */
    run(16, 1000, 10, 5);      /* almost everything empty */
    run(1000, 1000, 50, 5);    /* normal density */
    run(1000, 100, 50, 5);     /* a battle: everyone sees everyone, always capped */
    run(1000, 250, 50, 5);     /* mixed capped and not */
    run(5000, 1253, 50, 5);    /* benchmark density */
    run(4096, 100000, 3, 5);   /* grid clamped to its maximum */
    run(1000, 1000, 50, 6);    /* wide ids */
    run(1000, 100, 50, 6);     /* wide ids, always capped */
    }
    printf(failures ? "FAILED: %d checks\n" : "all tests passed\n", failures);
    return failures != 0;
}
