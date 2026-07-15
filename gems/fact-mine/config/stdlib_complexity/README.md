# Standard-library complexity mappings

Fact-Mine owns the language-specific standard-library spellings used to emit
normalized complexity facts. Espalier consumes only those facts and performs
language-neutral symbolic algebra; it must not load a per-language operation
table or infer a cost from source text.

Each `<language>.yml` maps a normalized receiver family (`Array`, `Hash`,
`Set`, `String`, or a nominal library type) and method spelling to one of:

- `constant`
- `linear_scan`
- `linear_materialize`
- `sort`
- `pairwise`

Adding a mapping requires a minimal Fact-Mine/Espalier golden fixture that
proves both the emitted fact and rendered time/space result. Unknown calls are
deliberately left unmapped and are emitted with an evidence-gap reason rather
than guessed by a downstream analyzer.
