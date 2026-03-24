/*
 * SIMD Benchmark — C Baseline (Explicit AVX2)
 *
 * Vec4 dot product: 10 million iterations.
 *
 * SIMD strategy: a Vec4 is exactly 4 doubles = 256 bits = one AVX register.
 * We load both vectors with _mm256_set_pd, multiply all 4 pairs in a single
 * _mm256_mul_pd instruction, then do a 2-step horizontal reduction.
 *
 * Total per-call cost (AVX2):
 *   2x _mm256_set_pd   (load)
 *   1x _mm256_mul_pd   (4-wide multiply — the key SIMD win)
 *   1x _mm256_castpd256_pd128
 *   1x _mm256_extractf128_pd
 *   1x _mm_add_pd
 *   1x _mm_hadd_pd
 *   1x _mm_cvtsd_f64
 *
 * CLEAR comparison:
 *   4x fmul + 3x fadd = 7 scalar FP ops (no hardware parallelism).
 *
 * Requires: x86 AVX2 + FMA (Sandy Bridge or newer; confirmed on this machine).
 * Compile:  gcc -O3 -mavx2 -mfma bench.c -o bench_c
 *   (runner.rb passes -O3 only; use the manual command above for best results)
 */

#pragma GCC target("avx2,fma")
#pragma GCC optimize("O3,unroll-loops")

#include <immintrin.h>
#include <stdio.h>
#include <stdint.h>
#include <assert.h>
#include <time.h>

typedef struct { double x, y, z, w; } Vec4;

/* Explicit AVX2 dot product: multiply all 4 pairs in one instruction. */
static inline double dot4_avx2(Vec4 a, Vec4 b) {
    /* _mm256_set_pd fills a 256-bit register: [w, z, y, x] */
    __m256d va = _mm256_set_pd(a.w, a.z, a.y, a.x);
    __m256d vb = _mm256_set_pd(b.w, b.z, b.y, b.x);
    /* 4-wide parallel multiply */
    __m256d prod = _mm256_mul_pd(va, vb);
    /* Horizontal reduction: [p3,p2,p1,p0] → p0+p1+p2+p3 */
    __m128d lo   = _mm256_castpd256_pd128(prod);          /* [p1, p0] */
    __m128d hi   = _mm256_extractf128_pd(prod, 1);        /* [p3, p2] */
    __m128d sum2 = _mm_add_pd(lo, hi);                    /* [p1+p3, p0+p2] */
    __m128d sum1 = _mm_hadd_pd(sum2, sum2);               /* [p0+p1+p2+p3, ...] */
    return _mm_cvtsd_f64(sum1);
}

int main(void) {
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    const int64_t N = 10000000;
    double sum = 0.0;
    for (int64_t i = 0; i < N; i++) {
        Vec4 a = { (double)i, (double)(i + 1), (double)(i + 2), (double)(i + 3) };
        Vec4 b = { 1.0, 2.0, 3.0, 4.0 };
        sum += dot4_avx2(a, b);
    }

    assert(sum > 0.0);

    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed = (end.tv_sec  - start.tv_sec) +
                     (end.tv_nsec - start.tv_nsec) / 1e9;

    printf("sum = %.6f\n", sum);
    printf("Time: %.4f seconds\n", elapsed);
    return 0;
}
