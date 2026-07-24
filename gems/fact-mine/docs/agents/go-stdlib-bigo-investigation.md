# Go stdlib/vendor Big-O completeness investigation

## Question

Would running our full Big-O analysis over the Go standard library (and vendor
packages), then consuming those per-function bounds as known callee
complexities, **substantially** increase `complete` Big-O coverage for Go
packages? If yes, decide whether to build it.

This extends two existing docs:
- `fact-mine/docs/agents/stdlib-complexity-registry-audit.md` - the hand-authored
  stdlib *name-mapping* registry. It gave Go **+0** complete functions, because
  it only maps intrinsics (`len`/`cap`/typed slice/map/string ops), not the
  high-frequency packages (`fmt`, `filepath`, `os`).
- `fact-mine/docs/agents/minimal-call-graph-feasibility.md` - concluded "don't
  build," but measured on **`compiler/ruby`**, where blockers are dynamic
  dispatch / receiver ambiguity. Go is statically typed with explicit,
  package-qualified stdlib calls, so that conclusion does not transfer unexamined.

## Method

Sampled two real, low-dependency Go repos: `~/unslop` (157 fns) and
`gems/boobytrap/src` (131 fns). For each:
1. `espalier -f architecture` -> per-function `time_complete` + `big_o_time`
   (the known structural component).
2. `espalier -f unknown_operations` -> ranked operations blocking completeness,
   with the incomplete functions each one blocks.
3. Classified every blocking operation against GOROOT's authoritative package
   set (`/usr/lib/go-1.22/src`, 224 leaf packages) and the repo's own packages:
   stdlib call / project call / typed receiver-method / unresolved-or-callback.
4. Per incomplete function, required **both** a concrete known structural
   component **and** all call-blockers resolvable, to count it "completable".
5. Ran the analysis over the hot stdlib packages themselves to measure how many
   stdlib functions actually yield a usable bound.

## Findings

### 1. Go's incompleteness IS call-dominated (unlike Ruby)

Current `time_complete`: unslop 18% (29/157), boobytrap 30% (39/131).

Of the incomplete functions, the blocker composition (unslop / boobytrap):

| Blocker category | unslop | boobytrap | stdlib analysis helps? |
|---|---:|---:|---|
| concrete structure + only stdlib/project calls | 49 (38%) | 36 (39%) | **yes** |
| + also typed stdlib-type receiver methods | 12 (9%) | 1 (1%) | yes, with type modeling |
| unresolved receiver / callback call | 28 (22%) | 9 (10%) | no |
| structurally unbounded loop / recursion | 39 (30%) | 46 (50%) | no |

Naive ceiling if analyzed stdlib bounds were complete and consumed:
unslop **18% -> 50%**, boobytrap **30% -> 57%** - roughly a doubling. `fmt`,
`filepath`, `os`, `exec` are the dominant blockers. This is the opposite of the
Ruby registry result and confirms the call-blocker lever is real for Go.

### 2. But the naive ceiling is not realizable by pure analysis

The Go stdlib **itself is only 33% complete** when we analyze it (170/515 fns
over `fmt`, `path/filepath`, `strconv`, `strings`, `sort`). Worse, the
highest-frequency blockers are themselves incomplete:

- Complete: `filepath.Join` O(1), `filepath.ToSlash` O(N).
- Incomplete: `fmt.Sprintf/Errorf/Fprintf` (reflection over `interface{}`),
  `filepath.Base/Dir/Ext`, `strconv.Itoa/Atoi`.

`fmt.*` alone is ~40% of stdlib-call blocker occurrences and is reflection-based;
callback-takers (`sort.Slice`, `filepath.WalkDir`) are input-dependent. Feeding
an *incomplete* stdlib bound does not complete the caller (completeness is
transitive), so pure automated stdlib analysis realizes only a fraction of the
50%/57% ceiling.

### 3. Vendor adds ~nothing for these repos

Both repos are near-zero-dependency; the "project/vendor" blocker share was
negligible. Vendor's value is entirely repo-specific and only shows up on
dependency-heavy code (e.g. fzf). It should not be built or judged until
measured on such a repo.

### 4. Hard ceiling ~55-60%

Structurally unbounded loops/recursion (30-50%) and unresolved
receivers/callbacks (10-22%) are untouched by any external-bound work. Even a
perfect stdlib+vendor+type model caps Go `complete` near 55-60%, not 80%.

## Determination

**Yes, external stdlib bounds are the single largest fixable lever for Go
completeness - but "run the analysis over GOROOT and consume it" is the wrong
build.** The stdlib's own hot functions are incomplete or reflection/callback
dependent, so automated consumption yields little.

The substantial, tractable win is a **curated authoritative-bound table for the
top ~20-30 highest-frequency Go stdlib functions** (`fmt.Sprintf/Errorf/Fprintf`,
`filepath.*`, `os.*`, `strconv.*`, `strings.*`), where:
- Espalier's analysis over the stdlib supplies the **draft** known component
  (e.g. `filepath.Base` = O(N+M)) - it does the tedious first pass.
- A human closes the reflection/callback cases with a sound semantic bound
  (e.g. `fmt.Sprintf` = O(total input size)) and promotes correct-but-marked-
  incomplete bounds to authoritative.
- The result lands in the existing `config/stdlib_complexity/go.yml`, extending
  the registry the audit found too sparse - not a new subsystem.

This is analysis-*assisted registry curation*, ranked by the
`unknown_operations` occurrence counts, not a full stdlib-analysis pipeline.

## Recommended validation before building

Cheap prototype to convert the ceiling into a measured number: assert
authoritative bounds for the top ~25 Go stdlib functions in `go.yml`, re-run
architecture analysis on unslop + boobytrap + one dependency-heavy repo (fzf),
and measure the real `time_complete` delta. Build the curation effort only if
that delta clears an agreed bar (suggest: +15 absolute percentage points).

## Reproduction

```sh
# per-function completeness + blockers
espalier -f architecture       -o arch.json    <go files...>
espalier -f unknown_operations -o unknown.json <go files...>
# stdlib self-completeness
espalier -f architecture -o stdlib.json \
  /usr/lib/go-1.22/src/{fmt,path/filepath,strconv,strings,sort}/*.go  # exclude _test
```
