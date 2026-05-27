# Fuzz Escape Gap Audit

Date: 2026-05-23

Goal: drive escape-related branch coverage from fuzz alone toward 100%.

## Current Finding

The existing fuzz templates were missing many AST-bound escape mechanisms even
though the surface registry named the broad concepts. The missing axis was not
only value shape; it was the concrete AST node that triggers escape analysis:

- `RETURN` of local owned bindings.
- `YIELD` from `BG STREAM`.
- `BG` / `BG STREAM` capture of an outer binding.
- Store into an enclosing-scope binding.
- Store into an enclosing-scope field.
- Store into an enclosing-scope index.
- Store into heap-backed containers through list/set/map/pool methods.
- Collection literal containing an owned binding.
- Function argument, `TAKES`, and `GIVE` argument transfer.
- A binding initialized from a heap-returning call and then stored elsewhere.
- `OR` / fallback call-return provenance.

## Added Coverage

`tools/fuzz/templates/escape_mechanism_matrix.rb` now owns this mechanism axis.
It currently has 18 cells:

- 7 active cells that pass and contribute coverage.
- 11 `:in_dev` cells that expose real runtime leaks today.

The `:in_dev` cells are not deleted or hidden; they reserve the matrix slots so
fixing the compiler means flipping them directly into the gate.

## Active Cells

- `return_string`
- `return_list`
- `yield_string_stream`
- `bg_capture_string`
- `bg_stream_capture_outer`
- `outer_assignment_loop`
- `outer_field_store_loop`

## In-Dev Cells Exposing Bugs

These should become active once the underlying escape/cleanup bugs are fixed:

- `outer_index_store_loop`
- `list_append_loop`
- `set_insert_loop`
- `map_put_loop`
- `pool_insert_loop`
- `collection_literal_return`
- `function_arg`
- `takes_arg`
- `give_arg`
- `call_return_receiver`
- `or_rescue_return_receiver`

Each leaked in an end-to-end fuzz bundle when marked `:pass`.

## Fuzz-Only Measurement

Before adding `escape_mechanism_matrix`:

- Global branch coverage: 38.69%.
- SlopCop true gaps: 155.
- `src/mir/escape_graph.rb`: 230/329 branches covered (69.9%).
- `src/mir/mir_checker.rb`: 177/457 branches covered (38.7%).
- `src/mir/mir_pass.rb`: 177/259 branches covered (68.3%).
- `src/mir/mir_lowering.rb`: 287/667 branches covered (43.0%).
- `src/mir/lowering/variables.rb`: 126/290 branches covered (43.4%).

After adding `escape_mechanism_matrix`:

- Global branch coverage: 38.97%.
- SlopCop true gaps: 154.
- `src/mir/escape_graph.rb`: 232/329 branches covered (70.5%).
- `src/mir/mir_checker.rb`: 183/457 branches covered (40.0%).
- `src/mir/mir_pass.rb`: 180/259 branches covered (69.5%).
- `src/mir/mir_lowering.rb`: 294/667 branches covered (44.1%).
- `src/mir/lowering/variables.rb`: 139/290 branches covered (47.9%).

## Next Architectural Work

The blocker to near-100% fuzz coverage is no longer "missing templates" alone.
Many missing cells are now explicit but cannot be active because they surface
real leaks. The next work is to make the escape/cleanup pipeline authoritative
for these sinks, then flip the `:in_dev` cells to `:pass`.

The highest-value sequence is:

1. Fix enclosing index/collection stores so loop-local owned bindings stored
   into outer list/set/map/pool/field/index destinations get the same heap
   storage decision.
2. Fix owned function argument / `TAKES` / `GIVE` String paths so the callee
   ownership contract decides cleanup exactly once.
3. Fix call-return provenance stored into containers so a heap-returning call
   cannot be consumed as a frame value.
4. After those pass, rerun fuzz-only SlopCop and burn down remaining genuine
   gaps by adding cells only where a still-uncovered branch maps to a real
   input shape.
