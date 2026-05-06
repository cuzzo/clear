# Benchmark 23: Pipeline Overhead

Measures the abstraction tax of CLEAR's `|>` pipeline operators vs handwritten loops. 10M float64 elements, 20 iterations each.

`BENCH_RESULT` = sum loop (handwritten), used for cross-language comparison.

## Cross-language: handwritten sum loop

| Language | Sum loop (20x 10M) | vs C |
|----------|--------------------|------|
| C | ~103ms | baseline |
| CLEAR | ~194ms | +88% |
| Go | ~198ms | +92% |

CLEAR and Go are comparable. The 2x gap to C is the cost of CLEAR's `FOR` loop overhead (saveLoopMark/restoreLoopMark calls) vs C's tight `for` loop. Using `TIGHT WHILE` in CLEAR would close this gap.

## CLEAR internal: pipeline overhead

| Test | Handwritten | Pipeline | Overhead |
|------|-------------|----------|---------|
| SUM only (`|> SUM _`) | 194ms | 194ms | 0ms (0%) |
| WHERE + SELECT + SUM (2-stage) | 285ms | 292ms | +7ms (+2.5%) |
| WHERE + SELECT + WHERE + SUM (4-stage) | 974ms | 1047ms | +73ms (+7.5%) |

- **Zero-alloc pipelines** (`SUM _`) compile to identical code as handwritten loops.
- **Multi-stage pipelines** pay for intermediate list allocations: one per `WHERE`/`SELECT` stage that materializes results.
- The 4-stage overhead is higher (~73ms) because two intermediate lists are allocated and freed per iteration × 20 iterations.
