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

## Second pass: C, C#, JavaScript, and TypeScript

Date: 2026-07-15

Tool revision: `8f88183a099a0ab51e8bb792d66e7f0fe7b8933f`

### Scope and method

This pass covers the remaining repositories requested from Lineage's current
multi-language validation matrix:

- C: `libuv/libuv` at `5e7d51a8`
- C#: `serilog/serilog` at `6d9fc0b8`
- TypeScript: `colinhacks/zod` at `912f0f51`

Lineage does not name a JavaScript validation repository. Zod contains only five
tracked JavaScript/MJS configuration files, so those files were run separately
as a JavaScript smoke corpus. They are not a credible substitute for a
JavaScript application or library. Representative JavaScript analyzer-quality
claims remain unvalidated.

Production sources were analyzed separately from tests with Decomplex,
Espalier, and Nil-Kill static evidence. The highest-ranked results were checked
against source, as were conspicuous low-ranked or absent results in known
parser, event-loop, reflection, asynchronous, and recursive code.

Espalier crashed on all three production targets when invoked with `--vcs git`:
an empty module set reaches `each_slice(0)` in `aggregator.rb`. The architecture
findings below come from the same production targets without `--vcs`. This is a
real empty-input/VCS-target handling bug, not a property of the repositories.

### Executive findings

The tools identify many of the right large functions, but the results are not
yet trustworthy unattended for these languages:

1. Decomplex's broad hotspot ordering is useful in all three production
   corpora. It correctly elevates libuv process/event-loop state machines,
   Serilog conversion/parsing paths, and Zod parsing/schema-conversion paths.
2. Decomplex's state and root identities are not type-precise enough for C or
   TypeScript. It merges same-named fields across unrelated objects and treats
   common tokens as shared invariants.
3. Decomplex produces concrete false positives from missing binding and access
   semantics: C reassignment, C aggregate escapes, C# properties and
   snapshot/restore code, and TypeScript method binding/class declarations.
4. Espalier is useful as a large-file/large-owner locator, but its architecture
   model conflates C files and TypeScript modules with state-owning classes. Its
   privacy advice is unsafe for public libraries.
5. Espalier misses important loop, recursion, callback, async, and collection
   semantics. Its reports leave most interesting Big-O results incomplete and
   fail to form obvious collaboration graphs in libuv and Serilog.
6. Nil-Kill collects substantial CFG/DFG facts but emits empty standalone
   reports for every repository. Worse, C and C# record zero signatures and
   recommend adding types to already typed parameters.
7. JavaScript support is not adequately tested. Nil-Kill ignored three of
   Zod's five JavaScript files because they use `.mjs`, and Espalier crashed on
   the zero-function configuration corpus.

## C: libuv

### Run inventory

- Decomplex: 118 production files, 2,302 candidates, 802 convergence units,
  and 253 root-cause clusters.
- Espalier: 166 owners/modules, 1,538 functions, 1,087 state slots, and 6,209
  delegation edges.
- Nil-Kill: 118 files, 1,538 functions, 1,087 fields, 23,207 local flow-type
  facts, 37,423 type dependencies, 320 state types, 11,948 Type Next
  candidates, and zero report actions or diagnostics.

### Strong findings

The top production hotspots are directionally correct:

- Windows `uv_spawn` is a large process-construction and cleanup coordinator.
  Decomplex's nine-detector convergence and Espalier's collision ranking point
  at a genuinely difficult function.
- Platform `uv__io_poll` implementations in kqueue/Linux/SunOS/AIX are complex
  event-loop state machines. Their high decision, mutation, and lifecycle
  pressure is expected but valuable to surface.
- Windows pipe, filesystem, TTY, TCP, and UDP implementations contain real
  overlapped-I/O and request-lifecycle complexity.
- `uv__idna_toascii_label` contains repeated scans over the same label domain
  and is a legitimate algorithmic-complexity review target.

These are good triage results. The reports should describe them as deliberately
complex systems boundaries rather than implying that a high score alone is a
defect.

### Noise and incorrect findings

#### C reassignment invalidation is missing

The only Decomplex redundant-nil finding inspected is false.
`src/unix/stream.c:uv__stream_queue_fd` proves `queued_fds` non-null, assigns
the result of `uv__realloc` back to it, and then checks it for null. The
assignment must kill the earlier non-null proof. This is a language-neutral
data-flow invariant even though the triggering syntax is C.

#### Aggregate escape is not credited as a field read

Several high-confidence “dead state” findings are fields consumed by passing
their enclosing struct to an OS/library call or macro. Examples include
termios fields (`c_iflag`, `c_oflag`, `c_lflag`, `c_cflag`), `msg_iovlen`,
`internal_fields`, and active-handle bookkeeping. A C field cannot be declared
dead merely because there is no later syntactic `obj.field` read; aggregate
address escape and whole-object reads must conservatively consume its fields.

#### State identity is file/name-based rather than type-based

Espalier and Decomplex combine common member names such as `flags`, `cb`,
`handle`, `HighPart`, and `LowPart` across unrelated structs. Espalier then
models a C source file as a single stateful owner and derives enormous
lifecycle scores such as `2^N` states. This can locate large files, but it is
not an ownership model. C state identity needs struct/union type plus field,
with points-to confidence where the receiver type is unresolved.

#### Conditional compilation is flattened

Mutually exclusive platform and `#if` implementations are analyzed together.
That can inflate state, protocol, duplicate, and branch findings. Reports need
either a selected preprocessor/build profile or an explicit “union of build
configurations” label and lower confidence.

#### Root clusters are lexical noise

Clusters headed by bare names such as `handle`, `fd`, `NULL`, or `flags` join
unrelated functions. They are not one invariant whose repair would collapse
the cluster. Root identity must be binding/type/owner-aware before scatter is
actionable in C.

### Espalier gaps

- No collaboration mesh is produced despite 6,209 delegation edges. Libuv has
  an obvious loop/handle/request/callback architecture. Function-pointer target
  resolution, callback registration, cross-file calls, and typed receiver
  identity are not being assembled into that graph.
- Privacy recommendations based on repository-local calls are unsafe for an
  exported C library. Public headers and export macros must override
  whole-repository call evidence.
- Big-O warnings refer to `stdlib_complexity_ruby.yml` and leave most libc,
  platform, and libuv calls unresolved.
- Multiple loops over the same source range are rendered as independent
  symbols. For `uv__idna_toascii_label`, this produces a long polynomial rather
  than identifying repeated work over the label length. Domain provenance and
  equality need to survive through the DFG.
- Allocation/free, handle init/close, request completion, and callback-driven
  lifecycle boundaries are not modeled. These are among the highest-value
  architecture and correctness signals available in a C event-loop library.

### Nil-Kill assessment

Nil-Kill's evidence volume is large, but its C type integration is currently
misleading. It records zero signatures. Its top Type Next recommendation is
`uv_loop_init`'s `loop` parameter, which is explicitly declared
`uv_loop_t* loop`; another top recommendation is `uv_close`'s typed `handle`.
The C adapter extracts functions and fields but does not seed declared
parameter/return types into the CFG/DFG signature layer.

C pointer types also must not be equated with nullable contracts. `_Nonnull`,
SAL-style annotations, assertions, and flow checks can refine nullability, but
plain `T*` is not enough to claim either nullable or non-null. Nil-Kill should
distinguish “declared type known” from “nullability unknown.”

## C#: Serilog

### Run inventory

- Decomplex: 113 production files, 133 candidates, 29 convergence units, and
  33 root-cause clusters.
- Espalier: 95 owners, 619 functions, 230 state slots, 1,044 delegation edges,
  842 reads, and only 26 writes.
- Nil-Kill: 113 files, 619 functions, 230 fields, 2,708 local flow-type facts,
  5,321 type dependencies, 226 state types, 2,037 Type Next candidates, and
  zero report actions or diagnostics.

### Strong findings

- `SettingValueConversions.ConvertToType` is a real reflection/configuration
  conversion hub with many conversion modes and failure paths.
- `MessageTemplateParser.ParsePropertyToken` and related parser functions are
  legitimate decision-heavy hotspots.
- `PropertyValueConverter` performs recursive destructuring, reflection,
  scalar/sequence/structure selection, and cycle control. Its high ranking is
  useful.
- `Logger.Write`, `MessageTemplateTextFormatter.Format`, and the batching loop
  are appropriate secondary review targets because they coordinate public
  logging paths and multiple collaborators.

### Noise and incorrect findings

#### Snapshot/restore is mislabeled as stale derived state

Several Derived-State Staleness findings are ordinary, intentional dynamic
scope or recursion mechanics:

- `DepthLimiter` saves `_currentDepth`, enters recursive work, then restores it.
- `LogContext` stores a bookmark so a pushed ambient context can be unwound.
- `BatchingSink.TryWaitToReadAsync` snapshots a cached task before clearing the
  cache.
- `PropertyValueConverter` temporarily swaps and restores the set of seen
  names.

The detector needs binding/alias-aware snapshot and restoration recognition.
These should not be tuned away by lowering confidence globally.

#### C# property reads are missed

`EnricherStack.Enumerator._current` is reported as dead even though both
`Current` accessors return it. The very low total of 26 writes for 230 fields is
another sign that property accessors, expression-bodied members, initializers,
and assignment forms are not fully connected to state facts.

#### Predicate aliases compare fragments, not functions

“Exact Predicate Aliases” groups unrelated methods because each contains a
`return false` or `return true` branch. A shared return literal is not a
function clone. Exact aliases must compare normalized whole bodies (or matched
complete decision regions), not isolated return statements.

#### Neglected paths lose branch-family context

Suggestions in `SettingValueConversions` demand predicates from alternative
conversion branches, such as requiring a `type != null` guard in a distinct
static-member path. The detector needs path dominance and mutually exclusive
branch identity before proposing a missing check.

#### Root clusters are token clusters

Clusters on `null`, `is`, `out`, `var`, `Length`, and `Value` are lexical
frequency, not shared invariants. They should not be presented as one-fix
root causes.

### Missed signal

`BatchingSink.DrainOnFailure` contains a documented, potentially unbounded
`while (_queue.Reader.TryRead(...))` loop. Espalier reports an `O(1)` known
component and leaves the method unknown; the loop itself contributes no linear
domain. This is a direct C# `while`-loop extraction gap.

Other important missing capabilities are:

- LINQ pipeline cost. `ConvertToType` scans converter collections with
  `Where`/`Select`/`FirstOrDefault`, but the collection domain is unresolved.
- Recursive reflection/destructuring cost in `PropertyValueConverter`.
- Async and concurrency lifecycle semantics for `Channel`, `Task`,
  cancellation, `AsyncLocal`, and `[ThreadStatic]` state.
- Execution-context/thread-affinity risk. `DepthLimiter`'s recursion and
  `[ThreadStatic]` behavior deserve a concurrency-context signal, not a stale
  state warning.
- Collaboration structure. Serilog has a clear logger -> filter/enricher/sink/
  formatter pipeline, plus a batching subgraph, yet Espalier forms no
  collaboration mesh from 1,044 call edges.

Espalier also suggests privatizing library APIs based on repository-local
calls. C# public/protected visibility is an explicit API contract and must be
respected unless a closed-application mode is requested.

### Nil-Kill assessment

Nil-Kill records zero C# signatures. Its top recommendations are
`JsonValueFormatter.FormatLiteralValue`'s `value` and `output` parameters,
declared as `object? value` and `TextWriter output`. It similarly recommends
typing `JsonFormatter.Format`'s declared `LogEvent logEvent` parameter.

This contradicts the earlier validation claim that nullable signatures map
well in Serilog. The parser sees methods, but explicit nullable/non-nullable
signature facts do not reach Type Next. Until that is fixed, the 2,037-candidate
queue is dominated by false missing-type pressure and should not be surfaced to
users.

## TypeScript: Zod

### Run inventory

- Decomplex: 107 production files, 697 candidates, 157 convergence units, and
  55 root-cause clusters.
- Espalier: 546 modules/classes, 1,100 functions, 1,187 state slots, 1,669
  delegation edges, 2,270 reads, and 116 writes.
- Nil-Kill: 286 files, 783 owners, 1,221 methods, 1,262 fields, 750 signatures,
  3,976 local flow-type facts, 7,116 type dependencies, 958 state types, 2,803
  Type Next candidates, and zero report actions or diagnostics.

### Strong findings

- V3/V4 `_parse` methods for strings, objects, unions, and other schema types
  are correct parser/runtime hotspots.
- `from-json-schema.convertBaseSchema` and `convertSchema`, and
  `to-json-schema.finalize`, are large schema graph conversion boundaries.
- The large `schemas.ts` and `types.ts` implementation files deserve review,
  though their module-level architecture scores should not be interpreted as
  one class owning hundreds of fields.
- Nil-Kill at least preserves TypeScript signatures: unlike C/C#, the top
  `convertBaseSchema(schema: JSONSchema.JSONSchema, ctx: ConversionContext)`
  candidate is not evidence that all signatures disappeared. It indicates an
  incomplete local-flow/parameter seeding or dependency connection around a
  complex conversion function.

### Noise and incorrect findings

#### Module/type state is conflated

Decomplex and Espalier merge `_zod`, `_def`, `value`, `issues`, `def`, and
other common member names across unrelated schema objects and declarations.
Espalier then reports `schemas` as an owner with 115 states and 300 public
methods. That is module aggregation, not a coherent state-owning class.

TypeScript state identity must include the resolved interface/class/type when
known, and reports must separate module exports, top-level functions, and class
members.

#### Bound methods are reported as removable state

V3 constructor assignments such as `this.and = this.and.bind(this)`,
`this.brand = this.brand.bind(this)`, `this.catch = this.catch.bind(this)`, and
`this.isOptional = this.isOptional.bind(this)` are deliberate public bound
methods. Decomplex reports many as superfluous state. Bound-method
initialization needs its own representation rather than a field-write-only
heuristic.

#### Normal classes are called monkeypatches/reopens

False Simplicity reports standard TypeScript class declarations such as
`ZodArray` and `ZodError` as monkeypatch/reopen behavior. This is a clear
adapter classification bug.

#### Overloads inflate method and API counts

Overload declarations such as `ZodError.format`/`flatten` are counted as
separate methods. Only the implementation is an executable method; overload
signatures should attach to it as API/type metadata.

#### Root clusters again use bare lexical names

Clusters on `value`, `issues`, `length`, `typeof`, `input`, and `def` join
unrelated bindings. As in C and C#, this is not actionable root-cause evidence.

### Missed signal

- Union parsing cost is the number of union options multiplied by the cost of
  parsing the input under each option. Espalier records loops and unknown calls
  but does not express `options * parse_cost` or connect the option domain to
  the schema definition.
- JSON-schema conversion is recursive graph traversal with reference lookup,
  memoization/cycle behavior, and potentially repeated work. The report sees
  flat loops and unknown calls but does not identify the traversal topology.
- Async parsing/refinement paths and promise boundaries are not modeled as
  execution/lifecycle behavior.
- Dynamic code generation should be visible where Zod constructs generated
  validators/functions. This matters for performance, CSP/security review, and
  architecture, even when intentional.
- Zod maintains intentionally parallel V3 and V4 implementations. Similarity
  and architecture reports need version/compatibility identity so they can
  distinguish deliberate parallel APIs from accidental duplication.
- Espalier recommends privatizing public Zod methods from repository-local call
  evidence. That is unsafe for a library and especially noisy when overloads
  and module ownership are already inflated.

### Nil-Kill assessment

TypeScript is materially healthier than C/C# because 750 signatures survive.
However, the Markdown report still exposes none of the 2,803 Type Next
candidates, their unlock counts, or their confidence. The top candidate,
`convertBaseSchema`'s `schema`, unlocks 50 facts; that may be a valuable DFG
frontier, but the source parameter is already typed. Nil-Kill must explain what
fact is actually missing (for example, a local flow merge or generic
instantiation) rather than prescribing a redundant annotation.

## JavaScript smoke corpus

Zod's tracked JavaScript consists of two `.js` Rollup configuration files and
three `.mjs` Next/PostCSS/Vitest configuration files. These are small,
declarative build configurations rather than representative JavaScript program
logic.

- Decomplex analyzed all five explicit files and produced zero candidates,
  which is reasonable for this corpus.
- Nil-Kill's JavaScript scan recognized only the two `.js` files. It silently
  omitted all three `.mjs` files. It found object/array shapes but no functions,
  Type Next candidates, or review output.
- Espalier crashed because the corpus contains no recognized modules/functions
  and its aggregator attempts `each_slice(0)`.

Missing features are therefore clear even though detector precision cannot be
judged:

1. Nil-Kill source discovery must include `.mjs` (and should explicitly decide
   `.cjs`, JSX, and mixed JS/TS package behavior).
2. Espalier must accept a valid zero-function corpus and return an empty report,
   not crash.
3. The validation matrix needs a real JavaScript library/application with
   classes, closures, prototypes, asynchronous code, modules, and dynamic
   object shapes. TypeScript success cannot stand in for JavaScript success.
4. Method/class-centric architecture tools need useful module/object/closure
   ownership for idiomatic JavaScript rather than treating “no classes” as “no
   architecture.”

## Cross-language missing features and priority

### Correctness blockers

1. Preserve declared C and C# signatures through Fact-Mine CFG/DFG into
   Nil-Kill, and suppress Type Next recommendations for already typed slots.
2. Fix Espalier's `each_slice(0)` empty-input/VCS crash.
3. Make state/binding identity type- and scope-aware. This includes C
   reassignment invalidation, aggregate escape, C# property accessors, and
   TypeScript module/class/overload identity.
4. Require whole-body/whole-region equivalence for Exact Predicate Aliases and
   add dominance/branch-family constraints to Neglected Paths.
5. Respect explicit/public API surfaces before making privacy recommendations.

### High-value missing analysis

1. Resolve loop domains for C# `while`/collection APIs and preserve domain
   equality so repeated work is expressed in human terms.
2. Model direct and mutual recursion, including recursive parse/conversion cost
   and cycle/memoization behavior.
3. Build callback/async collaboration and lifecycle graphs: libuv handles and
   requests, Serilog sinks/batches, and Zod async parse/refinement paths.
4. Model allocation/resource protocols (`alloc/free`, `init/close`, request
   completion) and execution-context state (`Task`, cancellation,
   `AsyncLocal`, `[ThreadStatic]`).
5. Distinguish class ownership, module aggregation, file grouping, and lexical
   closures instead of forcing every language into one owner model.
6. Surface Nil-Kill's Type Next frontier in its standalone report with source,
   unlock count, confidence, and the precise missing fact. Static evidence that
   never reaches a review queue is not a useful user-facing analyzer.

### Recommended order

1. Fix false claims first: Nil-Kill typed-slot recommendations, Espalier's
   crash, Decomplex binding/state identity, and public-API privacy safety.
2. Add golden repository-independent regressions for C reallocation proof
   invalidation, aggregate escape, C# properties/`while`, TypeScript overloads
   and bound methods, and `.mjs` discovery.
3. Repair loop/recursion/domain provenance and only then evaluate Big-O
   thresholds or rendering.
4. Add a representative JavaScript validation repository before describing
   JavaScript support as production-quality.
5. Add callback/async/resource-protocol architecture once the owner and call
   identities are reliable. Otherwise richer detectors will amplify the same
   false joins documented above.

## Post-fix validation: C, C#, TypeScript, and JavaScript

Date: 2026-07-15

The concrete correctness and usability defects from the second pass were fixed
and then re-run against the production repositories. The validation JavaScript
target is now `fastify/fastify` at `de3752df84bb8dd35a8226bb467f05862f4da57c`;
it contains 265 tracked `.js`, `.mjs`, and `.cjs` source files and is a useful
server-side, callback-heavy complement to Zod's TypeScript corpus.

### Confirmed repairs

- FactMine retains C and C# declaration signatures, including typed pointer,
  nullable, and non-nullable parameters. Nil-Kill no longer emits a zero-
  signature C/C# inventory or asks to annotate declarations it has discarded.
- FactMine invalidates a non-null proof after assignment, including a C
  `realloc` assignment. The false `uv__stream_queue_fd` redundant-nil finding
  is gone.
- Decomplex treats a C/C++ aggregate pointer passed to an unknown function as
  an opaque possible read. FactMine supplies an owner-qualified state identity
  when C evidence proves a bare field name is ambiguous; Decomplex preserves
  the bare name unless that collision occurs. This prevents the demonstrated
  aggregate-escape dead-field and same-name-field false positives without
  weakening other language models.
- C# expression-bodied properties are executable methods, private-field reads
  are represented as state reads, and `while`/`do` loops are first-class
  complexity facts. `BatchingSink.DrainOnFailure` now has a linear `WHILE`
  fact at line 210 with `_queue` among its state domains. The normalized C#
  test also proves that a local named `_queue` does not mask `this._queue`.
- Predicate aliases require a whole predicate expression rather than a shared
  `return true`/`return false` fragment. Snapshot/restore is no longer called
  stale derived state.
- TypeScript/JavaScript module-like owners are not modeled as instance-state
  classes; paths qualify module ownership; implementation methods replace
  overload declarations; and `this.method = this.method.bind(this)` is not
  mutable state. Normal TypeScript classes are no longer classified as Ruby
  reopens.
- Espalier's VCS target discovery works from the target repository, accepts a
  zero-function project, and never computes `each_slice(0)`. Privacy advice is
  now emitted only in explicit closed-world mode rather than for a public
  library based solely on repository-local callers.
- Nil-Kill recognizes `.js`, `.mjs`, `.cjs`, and `node` as JavaScript, and its
  static report now displays the ranked Type Next frontier instead of hiding
  all actionable candidates.
- FactMine project workers now receive the same 64 MiB stack budget as the
  analyzer entrypoint. Fastify exposed the defect: every file succeeded alone,
  but the multi-file run overflowed a default-size scoped worker stack. The
  full 292-file static JavaScript run now completes.

### Re-run inventory

The following production/all-source evidence runs used the release FactMine
binary after the fixes:

| Repository | Espalier files / methods / complexity facts | Nil-Kill files / signatures / type dependencies |
| --- | ---: | ---: |
| libuv (C) | 104 / 1,536 / 1,446 | 368 / 2,664 / 75,732 |
| Serilog (C#) | 113 / 825 / 487 | 216 / 1,047 / 14,703 |
| Zod (TypeScript) | 286 / 1,221 / 884 | 286 / 750 / 7,116 |
| Fastify (JavaScript) | 292 / 758 / 543 | 292 / 28 / 6,365 |

Fastify also establishes that JavaScript static analysis now traverses mixed
`.js`/`.mjs`/`.cjs` sources instead of silently omitting ES modules. Its small
signature count is expected for unannotated JavaScript, not a discovery
failure: the static report contains 1,882 Type Next candidates and identifies
the top candidate with its 206-fact unlock count.

### Remaining, deliberately not overstated

The repairs make the prior reports materially safer, but they do **not** make
every high-level semantic claim exact. In particular, Zod's union parser still
needs a symbolic `options × dispatched-parser-cost` model, and JSON-schema
conversion needs recursion/cycle/memoization provenance. The current facts
identify the loops and recursive/unknown call sites, but cannot honestly turn
those dynamic calls into a complete polynomial. That requires a general
iterator-yield plus polymorphic-call-cost design, not a Zod-specific heuristic.

Likewise, the C# queue-drain fact is now surfaced as linear state-backed work,
but cancellation selectors and asynchronous channel semantics are not yet a
precise queue-length proof. These are retained as high-value cross-language
analysis work, rather than disguised as resolved complexity claims.
