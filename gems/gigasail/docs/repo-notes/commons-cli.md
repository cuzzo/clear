# commons-cli — Java

**Revision:** `8d56926d951f` · **Scope:** `src/main/java` · **Result:** the
parser itself is under-ranked relative to help formatting; no library defect is
claimed, but this is a quality gap in prioritization.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 36 files, 475 methods, 271 fields; Type Next is not applicable to Java. |
| Espalier | 283/471 bounds unknown (60.1%). `HelpFormatter.appendOptions` is top coordinator/owner pressure. |
| Decomplex | Only three convergences: two `Option` stringification methods and `DefaultParser.parse`. |

## Independent source audit

- `DefaultParser.parse`, token classification, and option consumption implement
  the package's core state machine: they scan arguments, mutate command-line
  state, and handle partial/ambiguous options. This is the highest-value
  operational review area.
- `HelpFormatter.appendOptions` has a large formatting/control surface but is
  normally presentation work. It can scale with option count, yet should not
  outrank parsing solely from conditional-call volume.
- `Option` formatting/stringification findings are low-risk negative controls:
  object representation is not central parser correctness.

## Assessment and follow-up

- The tools did find `DefaultParser.parse`, but ranking gives too much weight to
  formatted-output fan-out and too little to stateful token scanning. A parser
  loop/cursor + mutable option-state heuristic would improve prioritization.
- No probable performance/correctness bug was found. Big-O unknowns must be
  interpreted cautiously because Java collection/library summaries are sparse.

## Second-pass time/space audit

- **Partial evidence:** all 283 unknown time/space results retain components.
  `DefaultParser.parse`, option matching, and `HelpFormatter.appendOptions`
  are locally analyzable scans/formatting; the sample (`createMessage`,
  `addArg`, `addOption`) contains three under-specified standard-library uses.
- **Actual dominant work:** parsing is token count × option-prefix/match work,
  with list/map state and argument values as space; help rendering is option
  count × rendered text. The parser is more operationally important than the
  formatter even when both are linear.
- **Coverage verdict:** Java collection/string summaries and interprocedural
  parser cursor facts should be available. The unknown label is conservative,
  but the missed parser bound and ranking are analyzable shortcomings.
