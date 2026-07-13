# Semantha Prototype Results

## Status

This is a stopping-point result from 2026-07-11, not a production approval.
The frozen repository commit was `57aa600056daf16a570a7a47f852fbdc8454a101` and the
EmbeddingGemma revision was
`57c266a740f537b4dc058e1b0cda161fd15afa75`.

## Corpus and execution

- FactMine extracted 17,767 functions from every supported repository
  language.
- Empty, generated, and oversized inputs were excluded explicitly. Exact model
  tokenization found 62 clustering inputs over EmbeddingGemma's 2,048-token
  limit; no input was silently truncated.
- The complete clustering index contains 17,680 usable functions at 768 and
  256 Matryoshka dimensions.
- The retrieval index stopped at a durable checkpoint containing 14,848 of
  17,680 eligible functions (84.0%). All 40 preselected benchmark targets are
  present. The missing 2,832 records are the shortest inputs because indexing
  was ordered longest-first.

## Search result at the stopping point

Forty natural-language queries and their exact target functions were frozen
before retrieval rankings were inspected. All were marked non-name-matching.

| Method | Recall@5 | Recall@10 | MRR | nDCG@10 |
| --- | ---: | ---: | ---: | ---: |
| EmbeddingGemma 768 | 0.700 | 0.825 | 0.521 | 0.590 |
| Identifier lexical baseline | 0.300 | 0.300 | 0.197 | 0.215 |
| Full-source TF-IDF baseline | 0.075 | 0.150 | 0.047 | 0.063 |

This reaches the provisional search gate exactly and beats the strongest
lexical baseline by 0.40 Recall@5. It is promising evidence for a small local
semantic-search tool, but it must be rerun on the completed corpus and at 256
dimensions before production use.

## Architecture anomaly result

The complete 768-dimensional clustering run produced 106 fragmentation
communities; the 256-dimensional run produced 66. The top communities were
hundreds of functions spanning dozens of files and mixed broad compiler/report
responsibilities. They did not identify a bounded centralization task.

Dimension stability also failed:

- cross-file incongruity top-20 overlap: 0.70;
- top-50 overlap: 0.78;
- top-100 overlap: 0.70;
- top-30 fragmentation mean best Jaccard: 0.385;
- fragmentation communities with Jaccard at least 0.80: zero.

Some individual incongruity results were plausible, but the mandatory 0.80
stability gate failed and the ranking also surfaced test helpers and legitimate
boundary adapters. This is not reliable enough for a Lineage anomaly view.

## Decision

Do not invest in the proposed cross-file incongruity or conceptual
fragmentation UI. The current geometry is unstable and the clusters are too
broad to create reliable work.

The only justified follow-up is one bounded completion of the semantic-search
experiment. Resume the content-addressed retrieval index, rerun the same 40
queries at 768 and 256 dimensions, and keep a search-only CLI only if the full
corpus retains Recall@5 of at least 0.70, at least 0.10 lexical lift, and stable
top results. Do not treat search success as evidence for anomaly detection.
