# pipe_analysis.rb — storage-write audit (SIMP-15)

## Summary

`src/annotator-helpers/pipe_analysis.rb` writes `node.storage` in 32 places.
Each write is the single-writer for a SYNTHESIZED pipe-stage node it just
created or rewrote. NONE are duplicate decisions with the rest of the
escape-analysis stack.

## Classification

Each write happens inside an `analyze_*_op` method that owns the
synthesized output node's semantics. The storage value is inherent to the
operator's contract:

| Method | Line | Storage | Operator semantic |
|---|---|---|---|
| `analyze_collect_op` | 256 | `:heap` | COLLECT yields an owned T[] snapshot from observable→array |
| `analyze_collect_op` | 259 | `:stack` | COLLECT scalar fallback |
| `analyze_select_family_op` | 318 | `:frame` | MAP/FILTER/SELECT_MANY — frame-allocated buffer per chunk |
| `analyze_take_while_op` | 350 | `:frame` | TAKE_WHILE — frame buffer |
| `analyze_window_op` | 376 | `:frame` | WINDOW — frame buffer |
| `analyze_batch_window_op` | 453 | `:heap` | BATCH_WINDOW — caller owns batches |
| `analyze_join_op` | 515 | `:frame` | JOIN intermediate |
| `analyze_recover_op` | 531 | `:stack` | RECOVER passes scalar |
| `analyze_reduce_op` | 561 | `:stack` | REDUCE yields scalar |
| `analyze_limit_op` | 623 | `:frame` | LIMIT slice |
| `analyze_unnest_op` | 658 | `:frame` | UNNEST flatten |
| `analyze_distinct_op` | 707, 712 | `:heap` | DISTINCT owns the dedup set |
| `analyze_each_op` | 837 | `:frame` | EACH side-effect chunk |
| `analyze_skip_op` | 862 | `:frame` | SKIP slice |
| `analyze_tap_op` | 898 | inherit | TAP — pass-through, inherits LHS storage |
| `analyze_find_op` | 923 | `:stack` | FIND scalar |
| `analyze_any_op` | 945 | `:stack` | ANY scalar bool |
| `analyze_all_op` | 967 | `:stack` | ALL scalar bool |
| `analyze_count_op` | 989 | `:stack` | COUNT scalar |
| `analyze_sum_op` | 1019 | `:stack` | SUM scalar |
| `analyze_average_op` | 1042 | `:stack` | AVERAGE scalar |
| `analyze_min_op` | 1065 | `:stack` | MIN scalar |
| `analyze_max_op` | 1088 | `:stack` | MAX scalar |
| `analyze_shard_each_op` | 1124 | `:stack` | SHARD_EACH yields void |
| `analyze_auto_shard_each_op` | 1218 | `:stack` | auto-SHARD_EACH yields void |
| `analyze_shard_op` | 1391 | `:stack` | SHARD scalar |
| `analyze_concurrent_op` | 1619 | `:stack`/`:heap` | concurrent dispatch — heap when non-Void result |
| `analyze_concurrent_bounded_select_family_op` | 1661 | `:heap` | bounded concurrent SELECT — owned result list |
| `analyze_concurrent_bounded_each_op` | 1685 | `:stack` | bounded concurrent EACH — scalar |
| `analyze_concurrent_stream_select_family_op` | 1722 | `:heap` | stream concurrent SELECT — owned result list |
| `analyze_concurrent_stream_each_op` | 1751 | `:stack` | stream concurrent EACH — scalar |

## Conclusion

All 32 writes are **legitimate single-writer-for-synthesized-node**
decisions. The pipe rewriter is the authority on every pipe-stage node's
storage; downstream passes (EscapeGraph, annotator, MIR) READ these
stamps but do not re-derive.

No deletions required. No consolidation possible without removing the
synthesized-node creation itself (which would defeat the rewrite).

This catalog is the SIMP-15 deliverable; the rest of the consolidation
work (SIMP-11) treats these 32 writes as honest data points, not targets.
