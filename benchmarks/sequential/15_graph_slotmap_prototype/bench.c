#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define EDGE_COUNT 4
#define DEAD_INDEX UINT32_MAX

typedef struct {
    uint64_t build;
    uint64_t local_read;
    uint64_t edge_write;
    uint64_t random_read;
    uint64_t churn;
    uint64_t collapse;
    uint64_t sparse_scan;
    uint64_t local_checksum;
    uint64_t random_checksum;
    uint64_t sparse_checksum;
} Results;

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static uint32_t read_capacity(void) {
    const char *exact = getenv("BENCH_N");
    if (exact) {
        unsigned long value = strtoul(exact, NULL, 10);
        if (value >= 4096 && value <= 1048576) return (uint32_t)value;
    }
    double scale = 1.0;
    const char *scaled = getenv("BENCH_SCALE");
    if (scaled) scale = strtod(scaled, NULL);
    uint32_t capacity = (uint32_t)(1000000.0 * scale);
    return capacity < 4096 ? 4096 : capacity;
}

static uint32_t even_at_least(uint32_t value, uint32_t minimum) {
    if (value < minimum) value = minimum;
    return value + (value & 1u);
}

static uint32_t local_target(uint32_t i, uint32_t edge, uint32_t core) {
    return ((i % core) + edge + 1u) % core;
}

static uint32_t random_target(uint32_t i, uint32_t edge, uint32_t core) {
    return (i * 1664525u + (edge + 1u) * 1013904223u) % core;
}

static void print_results(const char *impl, uint32_t capacity, uint32_t live,
                          size_t peak_bytes, size_t retained_bytes,
                          const Results *r) {
    uint64_t combined = r->build + r->local_read + r->edge_write +
        r->random_read + r->churn + r->collapse;
    printf("BENCH_RESULT: %.3f ms\n", (double)combined / 1000000.0);
    printf("BENCH_INFO: impl=%s nodes=%" PRIu32 " live=%" PRIu32
           " peak_mib=%.2f retained_mib=%.2f bytes_per_capacity=%.1f"
           " local_checksum=%" PRIu64 " random_checksum=%" PRIu64 "\n",
           impl, capacity, live, (double)peak_bytes / (1024.0 * 1024.0),
           (double)retained_bytes / (1024.0 * 1024.0),
           (double)peak_bytes / capacity, r->local_checksum, r->random_checksum);
    printf("BENCH_PHASES: impl=%s build_ms=%.3f local_read_ms=%.3f"
           " edge_write_ms=%.3f random_read_ms=%.3f churn_ms=%.3f"
           " collapse_ms=%.3f sparse_scan_ms=%.3f sparse_checksum=%" PRIu64 "\n",
           impl, (double)r->build / 1000000.0, (double)r->local_read / 1000000.0,
           (double)r->edge_write / 1000000.0, (double)r->random_read / 1000000.0,
           (double)r->churn / 1000000.0, (double)r->collapse / 1000000.0,
           (double)r->sparse_scan / 1000000.0, r->sparse_checksum);
}

/* Best-case unsafe C: one contiguous allocation and raw pointer edges. Tail
 * churn overwrites unreferenced nodes in place; collapse changes the logical
 * length. This deliberately omits stale-reference protection and per-node
 * lifecycle work, making it a lower bound rather than equivalent semantics. */
typedef struct RawNode RawNode;
struct RawNode {
    uint64_t value;
    RawNode *edges[EDGE_COUNT];
};

static void run_perfect_c(uint32_t capacity, uint32_t read_rounds,
                          uint32_t write_rounds, uint32_t churn_rounds,
                          uint32_t sparse_rounds) {
    const uint32_t core = capacity * 3u / 4u;
    const uint32_t churn_count = capacity - core;
    RawNode *nodes = malloc((size_t)capacity * sizeof(*nodes));
    if (!nodes) abort();
    Results r = {0};
    uint64_t start = now_ns();
    for (uint32_t i = 0; i < capacity; i++) nodes[i].value = i;
    for (uint32_t i = 0; i < capacity; i++) {
        for (uint32_t edge = 0; edge < EDGE_COUNT; edge++)
            nodes[i].edges[edge] = &nodes[local_target(i, edge, core)];
    }
    r.build = now_ns() - start;

    start = now_ns();
    for (uint32_t round = 0; round < read_rounds; round++)
        for (uint32_t i = 0; i < core; i++)
            for (uint32_t edge = 0; edge < EDGE_COUNT; edge++)
                r.local_checksum += nodes[i].edges[edge]->value;
    r.local_read = now_ns() - start;

    start = now_ns();
    for (uint32_t round = 0; round < write_rounds; round++) {
        int use_random = (round & 1u) || round + 1u == write_rounds;
        for (uint32_t i = 0; i < capacity; i++)
            for (uint32_t edge = 0; edge < EDGE_COUNT; edge++) {
                uint32_t target = use_random ? random_target(i, edge, core)
                                             : local_target(i, edge, core);
                nodes[i].edges[edge] = &nodes[target];
            }
    }
    r.edge_write = now_ns() - start;

    start = now_ns();
    for (uint32_t round = 0; round < read_rounds; round++)
        for (uint32_t i = 0; i < core; i++)
            for (uint32_t edge = 0; edge < EDGE_COUNT; edge++)
                r.random_checksum += nodes[i].edges[edge]->value;
    r.random_read = now_ns() - start;

    start = now_ns();
    for (uint32_t round = 0; round < churn_rounds; round++) {
        for (uint32_t tail = 0; tail < churn_count; tail++) {
            uint32_t i = core + tail;
            nodes[i].value = (uint64_t)round + tail;
            for (uint32_t edge = 0; edge < EDGE_COUNT; edge++)
                nodes[i].edges[edge] = &nodes[random_target(tail, edge, core)];
        }
    }
    r.churn = now_ns() - start;

    start = now_ns();
    const uint32_t keep = capacity / 100u > 0 ? capacity / 100u : 1u;
    uint32_t live = keep;
    r.collapse = now_ns() - start;

    start = now_ns();
    for (uint32_t round = 0; round < sparse_rounds; round++)
        for (uint32_t i = 0; i < live; i++) r.sparse_checksum += nodes[i].value;
    r.sparse_scan = now_ns() - start;

    size_t bytes = (size_t)capacity * sizeof(*nodes);
    print_results("c-perfect-raw-pointers", capacity, live, bytes, bytes, &r);
    free(nodes);
}

/* Smaller ideal-C lower bound: direct unchecked u32 indices into a contiguous
 * array. It has neither stable identity after movement nor stale-ID checks. */
typedef struct {
    uint64_t value;
    uint32_t edges[EDGE_COUNT];
} IndexNode;

static void run_perfect_index_c(uint32_t capacity, uint32_t read_rounds,
                                uint32_t write_rounds, uint32_t churn_rounds,
                                uint32_t sparse_rounds) {
    const uint32_t core = capacity * 3u / 4u;
    const uint32_t churn_count = capacity - core;
    IndexNode *nodes = malloc((size_t)capacity * sizeof(*nodes));
    if (!nodes) abort();
    Results r = {0};
    uint64_t start = now_ns();
    for (uint32_t i = 0; i < capacity; i++) {
        nodes[i].value = i;
        for (uint32_t edge = 0; edge < EDGE_COUNT; edge++)
            nodes[i].edges[edge] = local_target(i, edge, core);
    }
    r.build = now_ns() - start;

    start = now_ns();
    for (uint32_t round = 0; round < read_rounds; round++)
        for (uint32_t i = 0; i < core; i++)
            for (uint32_t edge = 0; edge < EDGE_COUNT; edge++)
                r.local_checksum += nodes[nodes[i].edges[edge]].value;
    r.local_read = now_ns() - start;

    start = now_ns();
    for (uint32_t round = 0; round < write_rounds; round++) {
        int use_random = (round & 1u) || round + 1u == write_rounds;
        for (uint32_t i = 0; i < capacity; i++)
            for (uint32_t edge = 0; edge < EDGE_COUNT; edge++)
                nodes[i].edges[edge] = use_random ? random_target(i, edge, core)
                                                  : local_target(i, edge, core);
    }
    r.edge_write = now_ns() - start;

    start = now_ns();
    for (uint32_t round = 0; round < read_rounds; round++)
        for (uint32_t i = 0; i < core; i++)
            for (uint32_t edge = 0; edge < EDGE_COUNT; edge++)
                r.random_checksum += nodes[nodes[i].edges[edge]].value;
    r.random_read = now_ns() - start;

    start = now_ns();
    for (uint32_t round = 0; round < churn_rounds; round++) {
        for (uint32_t tail = 0; tail < churn_count; tail++) {
            uint32_t i = core + tail;
            nodes[i].value = (uint64_t)round + tail;
            for (uint32_t edge = 0; edge < EDGE_COUNT; edge++)
                nodes[i].edges[edge] = random_target(tail, edge, core);
        }
    }
    r.churn = now_ns() - start;

    start = now_ns();
    const uint32_t keep = capacity / 100u > 0 ? capacity / 100u : 1u;
    uint32_t live = keep;
    r.collapse = now_ns() - start;

    start = now_ns();
    for (uint32_t round = 0; round < sparse_rounds; round++)
        for (uint32_t i = 0; i < live; i++) r.sparse_checksum += nodes[i].value;
    r.sparse_scan = now_ns() - start;

    size_t bytes = (size_t)capacity * sizeof(*nodes);
    print_results("c-perfect-u32-index", capacity, live, bytes, bytes, &r);
    free(nodes);
}

typedef uint32_t Handle;
typedef struct {
    uint64_t value;
    Handle edges[EDGE_COUNT];
} SlotNode;
typedef struct {
    SlotNode *nodes;
    uint32_t *handle_to_dense;
    uint32_t *dense_to_handle;
    uint32_t *free_handles;
    uint32_t capacity;
    uint32_t live_count;
    uint32_t free_top;
} DenseGraph;

static DenseGraph graph_init(uint32_t capacity) {
    DenseGraph g = {
        .nodes = malloc((size_t)capacity * sizeof(SlotNode)),
        .handle_to_dense = malloc((size_t)capacity * sizeof(uint32_t)),
        .dense_to_handle = malloc((size_t)capacity * sizeof(uint32_t)),
        .free_handles = malloc((size_t)capacity * sizeof(uint32_t)),
        .capacity = capacity, .free_top = capacity,
    };
    if (!g.nodes || !g.handle_to_dense || !g.dense_to_handle || !g.free_handles) abort();
    for (uint32_t i = 0; i < capacity; i++) {
        g.handle_to_dense[i] = DEAD_INDEX;
        g.free_handles[i] = capacity - 1u - i;
    }
    return g;
}

static inline Handle graph_insert(DenseGraph *g, SlotNode node) {
    Handle handle = g->free_handles[--g->free_top];
    uint32_t dense = g->live_count++;
    g->nodes[dense] = node;
    g->dense_to_handle[dense] = handle;
    g->handle_to_dense[handle] = dense;
    return handle;
}

static inline SlotNode *graph_get(DenseGraph *g, Handle handle) {
    uint32_t dense = g->handle_to_dense[handle];
    return dense == DEAD_INDEX ? NULL : &g->nodes[dense];
}

static inline int graph_remove(DenseGraph *g, Handle handle) {
    uint32_t removed = g->handle_to_dense[handle];
    if (removed == DEAD_INDEX) return 0;
    uint32_t last = --g->live_count;
    if (removed != last) {
        g->nodes[removed] = g->nodes[last];
        Handle moved = g->dense_to_handle[last];
        g->dense_to_handle[removed] = moved;
        g->handle_to_dense[moved] = removed;
    }
    g->handle_to_dense[handle] = DEAD_INDEX;
    g->free_handles[g->free_top++] = handle;
    return 1;
}

static void run_unsafe_slotmap(uint32_t capacity, uint32_t read_rounds,
                               uint32_t write_rounds, uint32_t churn_rounds,
                               uint32_t sparse_rounds) {
    const uint32_t core = capacity * 3u / 4u;
    const uint32_t churn_count = capacity - core;
    DenseGraph g = graph_init(capacity);
    Handle *churn_handles = malloc((size_t)churn_count * sizeof(*churn_handles));
    Results r = {0};
    uint64_t start = now_ns();
    for (uint32_t i = 0; i < capacity; i++) {
        SlotNode node = {.value = i, .edges = {0, 0, 0, 0}};
        Handle handle = graph_insert(&g, node);
        if (i >= core) churn_handles[i - core] = handle;
    }
    for (uint32_t i = 0; i < capacity; i++)
        for (uint32_t edge = 0; edge < EDGE_COUNT; edge++)
            graph_get(&g, i)->edges[edge] = local_target(i, edge, core);
    r.build = now_ns() - start;

    start = now_ns();
    for (uint32_t round = 0; round < read_rounds; round++)
        for (uint32_t i = 0; i < core; i++) {
            SlotNode *node = &g.nodes[i];
            for (uint32_t edge = 0; edge < EDGE_COUNT; edge++)
                r.local_checksum += graph_get(&g, node->edges[edge])->value;
        }
    r.local_read = now_ns() - start;

    start = now_ns();
    for (uint32_t round = 0; round < write_rounds; round++) {
        int use_random = (round & 1u) || round + 1u == write_rounds;
        for (uint32_t i = 0; i < capacity; i++) {
            SlotNode *node = &g.nodes[i];
            for (uint32_t edge = 0; edge < EDGE_COUNT; edge++)
                node->edges[edge] = use_random ? random_target(i, edge, core)
                                               : local_target(i, edge, core);
        }
    }
    r.edge_write = now_ns() - start;

    start = now_ns();
    for (uint32_t round = 0; round < read_rounds; round++)
        for (uint32_t i = 0; i < core; i++) {
            SlotNode *node = &g.nodes[i];
            for (uint32_t edge = 0; edge < EDGE_COUNT; edge++)
                r.random_checksum += graph_get(&g, node->edges[edge])->value;
        }
    r.random_read = now_ns() - start;

    start = now_ns();
    for (uint32_t round = 0; round < churn_rounds; round++) {
        for (uint32_t tail = 0; tail < churn_count; tail++) {
            graph_remove(&g, churn_handles[tail]);
            SlotNode node = {.value = (uint64_t)round + tail, .edges = {0, 0, 0, 0}};
            for (uint32_t edge = 0; edge < EDGE_COUNT; edge++)
                node.edges[edge] = random_target(tail, edge, core);
            churn_handles[tail] = graph_insert(&g, node);
        }
    }
    r.churn = now_ns() - start;

    start = now_ns();
    const uint32_t keep = capacity / 100u > 0 ? capacity / 100u : 1u;
    for (uint32_t i = keep; i < core; i++) graph_remove(&g, i);
    for (uint32_t i = 0; i < churn_count; i++) graph_remove(&g, churn_handles[i]);
    r.collapse = now_ns() - start;

    start = now_ns();
    for (uint32_t round = 0; round < sparse_rounds; round++)
        for (uint32_t i = 0; i < g.live_count; i++) r.sparse_checksum += g.nodes[i].value;
    r.sparse_scan = now_ns() - start;

    size_t bytes = (size_t)capacity * (sizeof(SlotNode) + 3u * sizeof(uint32_t));
    print_results("c-unsafe-slotmap", capacity, g.live_count, bytes, bytes, &r);
    free(churn_handles);
    free(g.free_handles);
    free(g.dense_to_handle);
    free(g.handle_to_dense);
    free(g.nodes);
}

int main(void) {
    const uint32_t capacity = read_capacity();
    const uint32_t core = capacity * 3u / 4u;
    const uint32_t churn_count = capacity - core;
    const uint32_t read_rounds = even_at_least(9000000u / core, 12u);
    const uint32_t write_rounds = even_at_least(1000000u / capacity, 4u);
    const uint32_t churn_rounds = even_at_least(1000000u / churn_count, 4u);
    const uint32_t sparse_rounds = 100000000u / capacity > 100u
        ? 100000000u / capacity : 100u;
    run_perfect_index_c(capacity, read_rounds, write_rounds, churn_rounds, sparse_rounds);
    run_perfect_c(capacity, read_rounds, write_rounds, churn_rounds, sparse_rounds);
    run_unsafe_slotmap(capacity, read_rounds, write_rounds, churn_rounds, sparse_rounds);
    return 0;
}
