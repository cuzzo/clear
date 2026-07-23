# mistune — Python

**Revision:** `060f73ac87e8` · **Scope:** `src/mistune` · **Result:** no
probable product defect; parser complexity is real but the final time model is
mostly unavailable.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 35 files, 397 methods, 124 fields; 123 Type Next candidates. |
| Espalier | 332/397 time bounds unknown (83.6%). `InlineParser` is the top owner; `Include.parse` is the top coordinator. |
| Decomplex | 61 convergences: `InlineParser.parse_link`, `BlockParser.parse_block_quote`, `parse_setex_heading`, `process_text`, and list parsing. |

## Independent source audit

- `InlineParser.parse_link` scans source positions, labels, destinations, and
  nested syntax before producing a token. It is appropriately ranked: repeated
  source scans and regex/callback parsing are the parser's natural hot path.
- `BlockParser.parse_block_quote`, list parsing, and emphasis finalization all
  walk token/source ranges and can nest. Their cost depends on input shape;
  a flat `O(N)` label is not justified without modeling parser progress.
- `Include.parse` crosses filesystem/renderer boundaries. Its apparent
  coordinator pressure is credible, but it is not a CPU-complexity result.
- The paired `_can_open_emphasis`/`_can_close_emphasis` reports are useful
  maintainability leads, not automatically harmful duplication: Markdown edge
  rules deliberately differ.

## Assessment and follow-up

- Espalier finds the right parser regions but leaves too much unknown because
  regex, callbacks, and parser-combinator-like progression lack summaries.
- Decomplex's parser findings are mostly useful-but-low-confidence: dense
  grammar rules are expected. No source review yielded a probable library bug.
- A future oracle should distinguish monotonic cursor advancement from a
  repeatedly rescanned suffix; that is the key fact needed to identify actual
  quadratic Markdown cases.

## Second-pass time/space audit

- **Partial evidence:** 332/332 unknown time and space results retain a known
  component. `markdown` and `parse_link` are under-specified: their source
  cursor/range scans should expose input-length terms. `import_plugin` is an
  appropriate unknown because plugin import/callback work is external.
- **Actual dominant work:** block/inline parsing and token construction scale
  with source length, nesting, and emitted tokens; pathological re-scanning of
  nested emphasis/link ranges is the real potential superlinear risk. Space is
  token/state depth plus rendered output, not a constant parser frame.
- **Coverage verdict:** local cursor-progress and token-append facts are
  derivable and should be modeled. Plugin callbacks should remain parameterized
  opaque work. The tool finds the functions but misses their useful bounds.
