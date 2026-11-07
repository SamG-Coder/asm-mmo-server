/* baseline.c - the same single-threaded workload as `mmoserver bench`, in C.
 *
 * This exists to keep the assembly honest: if clang can match it, hand-written
 * assembly is not what makes the server fast. Not part of the server.
 *
 *   baseline_c       plain C, left to clang's optimizer
 *   baseline_intrin  -DUSE_INTRINSICS: the AOI scan hand-vectorized in AVX2
 *
 *   usage: baseline <players> <ticks> <world> <radius>
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <windows.h>
#ifdef USE_INTRINSICS
#include <immintrin.h>
#endif

#define MAX_VISIBLE 64
#define MAX_GRID 4096
#define MAX_SPEED 8.0f
#define PAD 64

static uint64_t rng = 0x9E3779B97F4A7C15ull;
static uint32_t rand32(void) {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return (uint32_t)((rng * 0x2545F4914F6CDD1Dull) >> 32);
}
static float randf(void) { return (float)rand32() * 2.3283064365386963e-10f; }

static void *alloc(size_t n) {
    return VirtualAlloc(NULL, n, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
}

static int cmp_u64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 10000;
    int ticks = argc > 2 ? atoi(argv[2]) : 1000;
    int world_i = argc > 3 ? atoi(argv[3]) : 1253;
    int radius_i = argc > 4 ? atoi(argv[4]) : 50;
    n = (n + 7) & ~7;
    SetThreadAffinityMask(GetCurrentThread(), 4); /* the same core as the server's worker 0 */

    float world = (float)world_i, r2 = (float)radius_i * (float)radius_i;
    float dt = 1.0f / 30.0f;
    union { float f; uint32_t u; } wm = {world};
    wm.u--;
    float world_max = wm.f;
    int gw = world_i / radius_i;
    if (gw > MAX_GRID) gw = MAX_GRID;
    float inv = (float)gw / world;
    int stride = gw + 2, ncells = stride * stride;

    size_t cnt = (size_t)n + PAD;
    float *restrict px = alloc(cnt * 4), *restrict py = alloc(cnt * 4);
    float *restrict vx = alloc(cnt * 4), *restrict vy = alloc(cnt * 4);
    float *restrict sx = alloc(cnt * 4), *restrict sy = alloc(cnt * 4);
    uint32_t *restrict cell = alloc(cnt * 4);
    uint32_t *restrict start = alloc(((size_t)ncells + 3 + PAD) * 4);
    uint32_t *restrict id = alloc(cnt * 4);
    uint8_t *out = alloc(65536);
    int entsize = n > 65536 ? 6 : 5;
    float relscale = 2047.0f / (float)radius_i;
    uint64_t *times = malloc(sizeof(uint64_t) * ticks);

    for (int i = 0; i < n; i++) {
        px[i] = randf() * world;
        py[i] = randf() * world;
        vx[i] = randf() * 2.0f * MAX_SPEED - MAX_SPEED;
        vy[i] = randf() * 2.0f * MAX_SPEED - MAX_SPEED;
    }

    LARGE_INTEGER freq, t0, t1;
    QueryPerformanceFrequency(&freq);
    uint64_t visible = 0, total = 0, sink = 0;

    for (int t = -16; t < ticks; t++) {
        QueryPerformanceCounter(&t0);

        for (int i = 0; i < n; i++) {
            float x = px[i] + vx[i] * dt, y = py[i] + vy[i] * dt;
            float cxv = x < 0 ? 0 : (x > world_max ? world_max : x);
            float cyv = y < 0 ? 0 : (y > world_max ? world_max : y);
            vx[i] = cxv != x ? -vx[i] : vx[i];
            vy[i] = cyv != y ? -vy[i] : vy[i];
            px[i] = cxv;
            py[i] = cyv;
        }

        for (int i = 0; i < n; i++) {
            int cx = (int)(px[i] * inv), cy = (int)(py[i] * inv);
            if (cx > gw - 1) cx = gw - 1;
            if (cy > gw - 1) cy = gw - 1;
            cell[i] = (uint32_t)((cy + 1) * stride + cx + 1);
        }
        memset(start, 0, ((size_t)ncells + 3) * 4);
        for (int i = 0; i < n; i++) start[cell[i] + 2]++;
        for (int c = 2; c < ncells + 3; c++) start[c] += start[c - 1];
        for (int i = 0; i < n; i++) {
            uint32_t j = start[cell[i] + 1]++;
            sx[j] = px[i];
            sy[j] = py[i];
            id[j] = (uint32_t)i;
        }

        for (int i = 0; i < n; i++) {
            float x = px[i], y = py[i];
            int c = (int)cell[i] - stride;
            int count = 0;
            for (int row = 0; row < 3 && count < MAX_VISIBLE; row++, c += stride) {
                uint32_t b = start[c - 1], e = start[c + 2];
#ifdef USE_INTRINSICS
                __m256 mx = _mm256_set1_ps(x), my = _mm256_set1_ps(y), mr = _mm256_set1_ps(r2);
                for (uint32_t j = b; j < e && count < MAX_VISIBLE; j += 8) {
                    __m256 dx = _mm256_sub_ps(_mm256_loadu_ps(sx + j), mx);
                    __m256 dy = _mm256_sub_ps(_mm256_loadu_ps(sy + j), my);
                    __m256 d2 = _mm256_fmadd_ps(dy, dy, _mm256_mul_ps(dx, dx));
                    uint32_t m = (uint32_t)_mm256_movemask_ps(_mm256_cmp_ps(d2, mr, _CMP_LE_OQ));
                    if (e - j < 8) m &= (1u << (e - j)) - 1;
                    if (!m) continue;
                    __m256 scale = _mm256_set1_ps(relscale), offset = _mm256_set1_ps(2048.5f);
                    __m256i qx = _mm256_cvttps_epi32(_mm256_add_ps(_mm256_mul_ps(dx, scale), offset));
                    __m256i qy = _mm256_cvttps_epi32(_mm256_add_ps(_mm256_mul_ps(dy, scale), offset));
                    uint32_t pos[8];
                    _mm256_storeu_si256((__m256i *)pos, _mm256_or_si256(qx, _mm256_slli_epi32(qy, 12)));
                    while (m) {
                        uint32_t lane = _tzcnt_u32(m);
                        uint64_t entry = pos[lane] | ((uint64_t)id[j + lane] << 24);
                        memcpy(out + count++ * entsize, &entry, 8);
                        m &= m - 1;
                    }
                }
#else
                for (uint32_t j = b; j < e && count < MAX_VISIBLE; j++) {
                    float dx = sx[j] - x, dy = sy[j] - y;
                    if (dx * dx + dy * dy <= r2) {
                        uint32_t qx = (uint32_t)(dx * relscale + 2048.5f);
                        uint32_t qy = (uint32_t)(dy * relscale + 2048.5f);
                        uint64_t entry = qx | (qy << 12) | ((uint64_t)id[j] << 24);
                        memcpy(out + count++ * entsize, &entry, 8);
                    }
                }
#endif
            }
            visible += (uint64_t)count;
            sink += out[0];
        }

        QueryPerformanceCounter(&t1);
        if (t >= 0) {
            times[t] = (uint64_t)(t1.QuadPart - t0.QuadPart);
            total += times[t];
        }
    }

    qsort(times, ticks, sizeof(uint64_t), cmp_u64);
#define US(q) ((q) * 1000000ull / (uint64_t)freq.QuadPart)
    printf("players          : %d\n", n);
    printf("ticks            : %d\n", ticks);
    printf("tick avg us      : %llu\n", US(total) / ticks);
    printf("tick p50 us      : %llu\n", US(times[ticks / 2]));
    printf("tick p99 us      : %llu\n", US(times[ticks * 99 / 100]));
    printf("tick max us      : %llu\n", US(times[ticks - 1]));
    printf("ns/player/tick   : %llu\n",
           total * 1000000000ull / (uint64_t)freq.QuadPart / ((uint64_t)ticks * n));
    printf("avg entries/snap : %llu\n", visible / ((uint64_t)(ticks + 16) * n));
    printf("(sink %llu)\n", sink);
    return 0;
}
