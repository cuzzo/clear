# Review: Pipe Concurrent Facts

## Scope

Targets: `PipeAnalysis#analyze_concurrent_op` and related bounded/stream
select-family helpers in `src/annotator/helpers/pipe_analysis.rb`.

## /plan

1. Snapshot Decomplex and SlopCop for `pipe_analysis.rb`.
2. Identify repeated facts emitted by `analyze_concurrent_op`.
3. Replace repeated case dispatch only if the old inline decisions are deleted.
4. Regenerate metrics and keep only if Decomplex and SlopCop improve.

## Implementation Result

Kept.

Implemented:

- Added `concurrent_stream_source?` so `analyze_concurrent_op` no longer repeats
  the stream-source predicate across SELECT/WHERE/EACH and final stamping.
- Added `validate_concurrent_where_expression!`.
- Added `concurrent_select_family_result_type`.
- Deleted the duplicate SELECT/WHERE result-type case dispatch from both bounded
  and stream concurrent select-family analyzers.

Scrapped within the item:

- A broader `validate_concurrent_error_modifier!` extraction was tried and
  reverted because it worsened Decomplex convergence and SlopCop.

Metrics:

- SlopCop for `pipe_analysis.rb`: genuine gaps `31 -> 29`.
- Decomplex Broken Protocols: `510 -> 473`.
- Decomplex Missing Abstractions: `5 -> 3`.
- Decomplex convergence worsened `58 -> 61`, so this is a narrow keep, not a
  total victory.

Assessment:

Worth keeping in the smaller form. It deletes repeated SELECT/WHERE and stream
source decisions and improves the strongest protocol-count metric without
leaving a second path.
