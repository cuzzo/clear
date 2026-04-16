/* SOA vs AOS Layout Benchmark -- C
 *
 * Particle simulation: N particles, M iterations of position update.
 * 16 fields per particle (128 bytes). Hot loop touches only x/vx/y/vy
 * (4 of 16 fields = 25% utilization in AOS, 100% in SOA).
 *
 * Build: gcc -O3 bench.c -o bench_c -lm
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>

#define N_PARTICLES 100000
#define ITERATIONS  100

/* AOS layout: 512 bytes per particle (64 fields) */
typedef struct {
    double x, y, z;
    double vx, vy, vz;
    double mass, radius, charge;
    double ax, ay, az;
    double age, energy, temperature, pressure;
    double r01, r02, r03, r04, r05, r06, r07, r08;
    double r09, r10, r11, r12, r13, r14, r15, r16;
    double r17, r18, r19, r20, r21, r22, r23, r24;
    double r25, r26, r27, r28, r29, r30, r31, r32;
    double r33, r34, r35, r36, r37, r38, r39, r40;
    double r41, r42, r43, r44, r45, r46, r47, r48;
} Particle;

static Particle aos[N_PARTICLES]; /* 100K * 512 bytes = 50MB stack - use heap */

/* SOA layout: only the hot fields (what the loop actually touches) */
static double soa_x[N_PARTICLES], soa_y[N_PARTICLES];
static double soa_vx[N_PARTICLES], soa_vy[N_PARTICLES];

static void init_aos(void) {
    for (int i = 0; i < N_PARTICLES; i++) {
        aos[i] = (Particle){
            .x = (double)i, .y = (double)i * 2.0, .z = 0.0,
            .vx = 1.0, .vy = 0.5, .vz = 0.0,
            .mass = 1.0, .radius = 0.1, .charge = 0.0,
            .ax = 0.0, .ay = 0.0, .az = 0.0,
            .age = 0.0, .energy = 0.0, .temperature = 0.0, .pressure = 0.0,
        };
        /* r01..r48 zero-initialized by designated init */
    }
}

static void init_soa(void) {
    for (int i = 0; i < N_PARTICLES; i++) {
        soa_x[i] = (double)i;  soa_y[i] = (double)i * 2.0;
        soa_vx[i] = 1.0;  soa_vy[i] = 0.5;
    }
}

static double run_aos(void) {
    init_aos();
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    for (int iter = 0; iter < ITERATIONS; iter++) {
        for (int i = 0; i < N_PARTICLES; i++) {
            aos[i].x += aos[i].vx;
            aos[i].y += aos[i].vy;
        }
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);

    double sum = 0.0;
    for (int i = 0; i < N_PARTICLES; i++)
        sum += aos[i].x + aos[i].y;

    double elapsed = (t1.tv_sec - t0.tv_sec) * 1000.0
                   + (t1.tv_nsec - t0.tv_nsec) / 1e6;
    printf("AOS checksum: %.0f\n", sum);
    return elapsed;
}

static double run_soa(void) {
    init_soa();
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    for (int iter = 0; iter < ITERATIONS; iter++) {
        for (int i = 0; i < N_PARTICLES; i++)
            soa_x[i] += soa_vx[i];
        for (int i = 0; i < N_PARTICLES; i++)
            soa_y[i] += soa_vy[i];
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);

    double sum = 0.0;
    for (int i = 0; i < N_PARTICLES; i++)
        sum += soa_x[i] + soa_y[i];

    double elapsed = (t1.tv_sec - t0.tv_sec) * 1000.0
                   + (t1.tv_nsec - t0.tv_nsec) / 1e6;
    printf("SOA checksum: %.0f\n", sum);
    return elapsed;
}

int main(void) {
    /* Warm up */
    run_aos();
    run_soa();

    double aos_ms = run_aos();
    double soa_ms = run_soa();

    /* BENCH_RESULT = SOA (the fast path we compare against CLEAR) */
    printf("BENCH_RESULT: %.0f ms\n", soa_ms);
    printf("SOA vs AOS (%d particles x %d iters)\n", N_PARTICLES, ITERATIONS);
    printf("  AOS:         %.1f ms\n", aos_ms);
    printf("  SOA:         %.1f ms\n", soa_ms);
    printf("  Speedup:     %.2fx\n", aos_ms / soa_ms);

    return 0;
}
