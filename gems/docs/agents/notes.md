# Multi-Language Static-Analysis Audit Notes

Date: 2026-07-14
Tool revision: `a940cd8713fbccab11737647bd9540510134c4f9`

## Scope and method

This audit covers the two repositories called out in Lineage's multi-language
support documents:

- Go: `junegunn/fzf` at `24832e97ef9640e5f859ede8dc163cf3c27145cb`
- Python: `Textualize/rich` at `9d8f9a372cc5916fd4781fec207ced7ddac2f08f`

Each clean checkout was analyzed with Decomplex, Espalier, and Nil-Kill static
evidence. Reports were then checked against the source, concentrating on the
highest-ranked functions and files. Test and non-source pollution was evaluated
separately from detector correctness.

The audit is qualitative. A finding is called a true positive only when the
reported source actually exhibits the claimed shape. A complex function is not
automatically a defect; rendering engines and parsers often contain intentional
algorithmic complexity.

## Executive findings

The tools find the right broad hotspots in both repositories, but the current
reports are not yet reliable enough to consume without source-level review.
The most important problems are structural rather than threshold tuning:

1. Espalier's function-scoped Big-O evidence is sometimes owner/file-scoped.
   It attaches loops from unrelated functions to the ranked function in both Go
   and Python.
2. Espalier treats Python nested functions as public class/module methods.
   This corrupts method counts, privacy findings, and some architecture scores.
3. State identity is inconsistent. Python state appears both with and without
   `@`, and Decomplex/Espalier substantially overcount some owners' fields.
4. Decomplex's state read model misses Go indexed-map reads, Python context
   manager reads, and cross-object field reads. This creates high-confidence
   false “dead state” findings.
5. Decomplex's Go redundant-nil analysis does not respect short-declaration
   shadowing. All six fzf findings inspected were false.
6. Nil-Kill static produces a useful typed inventory but no ranked review signal
   for either repository: zero recommendations and zero actions.
7. Source-role and extension filtering are insufficient. Tests rank alongside
   production code, and a Go-only Decomplex run parsed 20 extensionless/non-Go
   files, including `.git/HEAD` and shell scripts.

There was also a valuable concrete result: Decomplex found what appears to be a
real Rich behavior bug. `ThemeContext` stores its `inherit` argument, but
`ThemeContext.__enter__` calls `push_theme(self.theme)` without forwarding it.
An `inherit=False` request is therefore ignored.

## Go: fzf

### Run inventory

- Nil-Kill: 80 files, 906 functions, 953 fields, 800 state types, 0 actions.
- Decomplex: 101 files, 2,126 candidates, 319 convergence units.
- Espalier source-focused run: 187 owners/modules, 909 functions, 955 state
  slots, 4,522 delegation edges.

Decomplex's 101 files comprise 81 `.go` files and 20 extensionless files. The
latter should not have been parsed as Go.

### Strong findings

#### `src/terminal.go` and `Terminal.Loop`

This is the correct top hotspot. `terminal.go` is 8,567 lines and `Loop` runs
from line 6035 to near the end of the file. It combines signal handling,
preview-subprocess lifecycle, event dispatch, rendering, keyboard and mouse
actions, request processing, and extensive terminal-state mutation.

Decomplex ranks it first with 13 converging detectors. Espalier also ranks it as
the largest coordinator/mutator collision. The architectural conclusion is
sound even though Espalier's attached Big-O evidence is not.

#### `src/core.go:Run`

`Run` is a roughly 590-line application coordinator. It constructs and wires
the reader, matcher, terminal, event channels, closures, ANSI processing, input
chunks, and shutdown behavior. Both tools correctly identify it as an
orchestration boundary with too many responsibilities.

#### `src/options.go:parseOptions` and `postProcessOptions`

The parser is a large stateful command-line decision engine, and post-processing
performs many dependent normalization/default phases. The high control-flow and
phase-boundary rankings are plausible and actionable.

#### `Terminal.UpdateList`, `resizeWindows`, and rendering functions

These methods genuinely mix substantial state mutation with branching and
delegation. They are useful secondary review targets after `Loop` and `Run`.

#### `algo.FuzzyMatchV2`

This is genuinely complex, but largely for a good reason: it is an explicit
multi-phase dynamic-programming fuzzy matcher with documented `O(N*M)` work and
a fallback to the greedy V1 algorithm when the matrix would be too large.
Ranking it as computationally complex is correct; presenting its DP locals as
architectural derived-state debt is mostly noise.

### Noise and incorrect findings

#### Go shadowing breaks every redundant-nil result inspected

Examples include `history.go:33`, `proxy.go:171`, `proxy.go:185`, and
`server.go:94`. In each case a Go short declaration such as
`if err := operation(); err != nil` introduces a new `err`. The earlier proof
belongs to another binding. These are not redundant guards.

This should be fixed in binding identity, not suppressed by a detector
threshold.

#### “Dead state” misses indexed reads

`Matcher.mergerCache` is reported as write-only even though it is read through
`m.mergerCache[patternString]`. `Terminal.numLinesCache` is likewise reported
dead despite `t.numLinesCache[item.Index()]` reads. Field/index projection needs
to preserve the root state identity.

Several other “derived cache” recommendations are ordinary retained
configuration or intentionally cached state, not evidence that the field can be
removed.

#### State counts are inflated

Espalier reports 282 state slots on `Terminal`; the Go struct declares 210
fields. Until synthetic/access-derived state is separated from declared state,
the owner score and “states=2^N” style interpretation are misleading.

#### Public API privatization is not whole-world safe

Espalier recommends privatizing `FuzzyMatchV1` based on one visible internal
caller. fzf selects it through a function value in option parsing, exercises it
directly in tests, and exposes the algorithm package to external Go consumers.
Absence of an in-repository direct call is not evidence that a public library
API can be made private.

#### Test and non-Go source pollution

Go `_test.go` owners rank in both reports, including `options_test` and
`terminal_test`. The initial repository-wide Espalier run also ranked Ruby
integration tests. Decomplex's Go run analyzed `.git/HEAD`, `install`,
`uninstall`, and other extensionless content; this produces nonsensical Go
state, predicate, and false-simplicity facts.

### Missed or corrupted signal

#### Espalier Big-O ownership is incorrect

`Terminal.Loop` starts at line 6035, but its Big-O variables include loops and
parameters at lines 1628, 2137, 2203, 2388, 2505, 5077, and elsewhere in other
methods. `printHighlighted` and `resizeWindows` show the same contamination.

The reported polynomial cannot be trusted until every loop/domain fact is
contained by the target function span or reached through a real call edge.

#### Go collaboration resolution is too sparse

Espalier records 4,522 delegation edges yet produces no collaboration mesh or
mediator candidate. fzf has obvious owner relationships among Terminal,
Matcher, Reader, Merger, renderer implementations, and EventBox. This suggests
receiver/call-target resolution is not strong enough to synthesize the owner
graph, rather than that fzf has no collaboration structure.

#### Function anchors should lead to the function entry

Decomplex links `Terminal.Loop` at line 7916 and `FuzzyMatchV2` at line 446,
which are detector-event lines rather than declarations at 6035 and 428. The
evidence line is useful, but the primary triage link should be the declaration,
with event lines nested beneath it.

### Nil-Kill assessment

Nil-Kill preserves useful Go structure and types, including `Slab.I16 []int16`
and `Slab.I32 []int32`. It captures 14,493 local type facts and 23,331 type
dependencies. The Markdown report nevertheless contains no ranked functions,
diagnostics, or actions. In static mode it is currently an evidence provider,
not a standalone code-review tool for typed Go.

## Python: Rich

### Run inventory

- Nil-Kill: 100 files, 910 functions, 755 fields, 631 signatures, 242 state
  types, 0 actions.
- Decomplex: 100 files, 1,125 candidates, 157 convergence units.
- Espalier: 188 owners/modules, 910 functions, 755 state slots, 2,690
  delegation edges.

### Strong findings

#### `rich/syntax.py:_get_syntax`

This is a real high-complexity rendering pipeline. It calculates layout,
handles a fast path, slices line ranges, applies indentation guides, wraps or
crops lines, adds line numbers/highlighting, and yields segments. Decomplex's
top convergence ranking and Espalier's conditional-hub ranking are reasonable.

#### `rich/markup.py:render`

This is a hand-written markup interpreter with tag stacks, implicit and explicit
closing rules, emoji handling, metadata parsing, error conversion, and span
construction. Its high decision and local-complexity pressure is real.

#### `rich/table.py:_render`

The method materializes cells, applies row/column styles, aligns multi-line
cells, renders nested row/column loops, and emits borders and section breaks.
It is a valid architecture and performance review target.

#### `rich/console.py`

The file is 2,698 lines and `Console` owns terminal detection, buffering,
rendering, recording, live-display state, export, Windows/Jupyter behavior, and
public presentation APIs. Its top owner-pressure rank is directionally correct.
`_write_buffer`, `export_svg`, and `_collect_renderables` are more useful review
targets than the constructor itself.

#### `rich/columns.py:__rich_console__`

This is both branchy and potentially expensive. It repeatedly tries column
counts and, inside the item loop, recomputes `sum(widths.values())`. The
worst-case work can grow cubically with the number of items/columns. The tools
rank the function, but Espalier renders the loop domains additively and misses
the important polynomial relationship.

#### Likely concrete bug: ignored `ThemeContext.inherit`

Decomplex reports `ThemeContext.inherit` as dead state. Source inspection shows:

- `Console.use_theme(theme, inherit=False)` constructs
  `ThemeContext(self, theme, inherit)`;
- `ThemeContext.__init__` stores `self.inherit`;
- `ThemeContext.__enter__` calls `self.console.push_theme(self.theme)` and omits
  `inherit=self.inherit`.

A direct execution check confirmed that `inherit=False` results in a
`push_theme` call with no keyword argument. This is a high-value true positive.
`ProgressBar._pulse_segments` and `ProgressColumn._update_time` also appear to
be genuinely unused fields, though they are cleanup rather than correctness
issues.

### Noise and incorrect findings

#### Nested functions are promoted to methods

Espalier reports `Console#check_text`, `Console#get_svg_style`,
`Console#make_tag`, and similar closures as public methods and recommends
privatizing them. They are nested functions, not callable members.

The corruption is measurable: the `Console` class has 71 direct method
definitions and seven nested functions; Espalier reports 78 methods. This is a
Python ownership-adapter bug and affects visibility, fan-out, method count,
privacy, and architecture pressure.

#### State identity and counts are inconsistent

Espalier separately ranks `plain` and `@plain`, `_spans` and `@_spans`, and
similar pairs on `Text`. Decomplex's temporal-ordering report claims 209 fields
for `Console`, 113 for `Text`, 96 for `Style`, and 77 for `Table`. Direct
`self.field` assignment inventories are 33, 10, 11, and 27 respectively.

The exponential lifecycle scores derived from the inflated field counts are
not meaningful.

#### “Dead state” misses valid access forms

`Console._record_buffer_lock` is reported dead but is used by four
`with self._record_buffer_lock` blocks. `TerminalTheme.ansi_colors` is read from
`Color`, `MarkdownLink.href` is read by its renderer, and several configuration
fields are externally observable public attributes. The read model needs
context-manager and typed cross-object projections.

#### Derived-state staleness is often a snapshot/rebinding false positive

In `markup.render`, the initial `Text(style=style)` intentionally snapshots the
argument; a later local `style = str(tag)` does not require rebuilding the
text. Similar reports arise when a loop variable name is reused for a later
phase. Binding identity and mutation/alias semantics are needed before these
can be treated as likely bugs.

#### Constructors dominate coordinator/mutator ranking

Espalier ranks `Console.__init__` and `Table.__init__` first and second largely
because constructors assign many fields. Initialization writes are not the same
as lifecycle mutation. Constructor scores should be separated or discounted so
operational methods such as `_write_buffer`, `_get_syntax`, and `_render` lead
the actionable queue.

#### Public-library privacy findings are unsafe

Candidates such as `Console.export_svg`, `Progress.add_task`,
`Progress.start_task`, and `RichHandler.render_message` are public APIs in a
library. Repository-local callers cannot establish that external consumers do
not use them. Some candidates are nested-function parser errors; the rest need
an explicit “closed application” mode or public-API manifest before suggesting
privatization.

### Missed or corrupted signal

#### Big-O function boundaries are wrong in Python too

`Syntax._get_syntax` begins at line 652, but its variables include loops at
512, 524, 533, 545, and 805 from other methods. `Table._render` includes loops
at 686 and 693 from `_get_cells`. The same defect exists in Go, so it belongs in
the language-neutral function/domain join.

#### Important polynomial and recursive costs are missed

- `markup.render` can scan the open-tag stack for each closing tag, giving a
  quadratic worst case, but Espalier reports additive domains.
- `Columns.__rich_console__` has nested retry/item/width-sum work, but its report
  lists independent additive symbols.
- `pretty._traverse` recursively visits object graphs, yet Espalier's overlap
  reports an `O(1)` known component.

These are not obscure language tricks. Nested lexical loops, helper-loop calls,
and direct recursion should work across languages.

#### Python Decision Pressure unexpectedly emits zero findings

Decomplex reports zero Decision Pressure candidates despite branch-heavy
functions such as `markup.render`, `_get_syntax`, `_write_buffer`, and
`Table._render`. Other detectors see the same decisions. This points to a
Python extraction/normalization gap, not an unusually simple codebase.

#### Architecture graph resolution is sparse

Espalier finds only one three-owner collaboration mesh (`Color`, `Style`,
`Text`) in a rendering library with many visible owner relationships. That mesh
is plausible, but the overall scarcity suggests missed qualified-call and
constructor/type resolution.

### Nil-Kill assessment

Nil-Kill captures substantial Python typing evidence: 631 signatures, 6,151
local flow types, 11,493 type dependencies, and 242 state types. It still emits
zero actions, alias recommendations, diagnostics, or ranked functions. As with
Go, static mode is currently useful as a fact source for other tools but does
not independently answer “what should I inspect next?”

Two CLI defaults are hazardous:

1. Static collection silently targets `src/`. Rich uses a top-level `rich/`
   package, so the first successful-looking run contained zero files. The CLI
   should discover standard package layouts or error when it selects no files.
2. `normalize` without `--traces` automatically consumed the current workspace's
   old Ruby traces, producing 211,213 diagnostics against the unrelated Rich
   run. Static-only normalization should mean no runtime traces unless a trace
   path is explicitly supplied.

## Shared tooling and CLI issues

### Decomplex launch path is stale

The documented `gems/decomplex/exe/decomplex` Ruby launcher requires
`../lib/decomplex`, but that library no longer exists after the Rust migration.
The audit had to invoke `gems/decomplex/target/debug/decomplex-rust` directly.

### Decomplex `--vcs git` is broken on a repository directory

The native CLI included `.git/HEAD` as an input and then attempted Git commands
from inside `.git`, producing “not inside a Git work tree.” Extension filtering
and VCS filtering need to happen before parsing or choosing the Git working
directory.

### Espalier emits a constant redefinition warning on every run

`Espalier::ROOT` is initialized by both `espalier.rb` and `static_helpers.rb`.
This is minor, but makes CI and scripted output unnecessarily noisy.

### Source roles need to be first-class

All three tools should preserve at least production, test, benchmark, example,
generated, vendored, and VCS-metadata roles. A source-focused report should rank
production by default while retaining a selectable test report. This is more
robust than repository-specific exclude lists.

## Recommended priority

1. Fix function containment for Big-O domains and add Go/Python golden tests
   proving that sibling-method loops cannot leak into a function.
2. Fix Python nested-function ownership and normalize each state slot to one
   identity.
3. Fix Go binding identity for short-declaration shadowing.
4. Fix state projection reads: indexed access, context managers, and typed
   cross-object fields.
5. Enforce extension/VCS/source-role filtering before analysis.
6. Separate constructor initialization from lifecycle mutation rankings.
7. Repair Decomplex's public launcher and Nil-Kill's zero-file/stale-trace
   defaults.
8. Add a useful Nil-Kill static review summary, or explicitly document it as an
   evidence-only command rather than implying it ranks functions.
9. Then tune thresholds. Threshold tuning before these identity and containment
   fixes would merely hide deterministic analysis errors.
