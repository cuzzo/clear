# Go stdlib/vendor Big-O completeness investigation

## Question

Would resolving external (stdlib/vendor) callee bounds substantially increase
`complete` Big-O for Go **production** code? Is >80% reachable? If so, what is
the smarter method, and should we build it?

Tests are excluded throughout: we care about the library/production runtime
complexity, not table-driven test harnesses.

## Method

Sampled `~/unslop` and `gems/boobytrap/src` (boobytrap is itself Go). For each,
`espalier -f architecture` (per-function `time_complete` + `big_o_time` known
component) and `-f unknown_operations` (ranked blockers + the functions each
blocks). Classified every blocker against GOROOT's 224-package set
(`/usr/lib/go-1.22/src`) and the repo's own packages. A function is "completable
by X" only if it has a concrete known structural component **and** all its
call-blockers are resolvable by X.

## Findings

### 1. For production Go, structural loops/recursion are a non-issue

The "structural ceiling" is a test-code artifact. Structurally-unbounded
(`big_o_time = None`) production functions:

| Repo | all fns | `_test.go` incl. structural-unknown | **production** structural-unknown |
|---|---:|---:|---:|
| unslop | 157 | 39 | **3** |
| boobytrap | 131 | 46 | **0** |

Test functions are table-driven (constant cases) or call unresolved `testing`
methods; they dominated the earlier "unbounded loop" bucket. Production Go loops
are almost all range-over-collection with a known cardinality domain, which the
existing analyzer already bounds.

### 2. Production completeness is gated by callee resolution, and it climbs fast

| Step (production only) | unslop (121 fns) | boobytrap (85 fns) |
|---|---:|---:|
| complete now | 24% | 46% |
| + stdlib/project package-call bounds | **64%** | **88%** |
| + typed stdlib-type receiver methods | **74%** | 89% |
| truly structural-unbounded (irreducible) | 3 fns | 0 fns |

The residual after package-call bounds is "unresolved receiver" calls. Inspected
directly, these are **overwhelmingly stdlib type methods on locals whose type
was not propagated**: `mu.Lock` (sync.Mutex), `wg.Done` (sync.WaitGroup),
`info.ModTime`/`info.Size` (os.FileInfo), `d.IsDir` (fs.DirEntry),
`f.Close`/`f.Fd` (*os.File), `flags.Bool` (*flag.FlagSet),
`inputBuf.WriteByte` (bytes.Buffer), `effTime.After` (time.Time). Only a few are
project methods. None are unbounded - each is O(1)/amortized-O(1) once the
receiver type is known. Resolving them pushes unslop from 74% toward **~90%**.

This matches `espalier/docs/agents/complexity-coverage.md`: "the dominant
remaining gap is **receiver/callee resolution, not loop or recursion
recognition**."

### 3. But raw analysis of the stdlib does not, by itself, deliver the bounds

The Go stdlib is only **33% complete** when analyzed (170/515 over
`fmt`,`filepath`,`strconv`,`strings`,`sort`), and the highest-frequency blockers
are themselves incomplete: `fmt.Sprintf/Errorf/Fprintf` (reflection - ~40% of
stdlib-call blockers), `filepath.Base/Dir/Ext`, `strconv.Itoa/Atoi`. Only
`filepath.Join`/`ToSlash` came back complete. Completeness is transitive, so
consuming an incomplete stdlib bound does not complete the caller. The bounds
must be **asserted** (a sound semantic bound, e.g. `fmt.Sprintf` = O(total input
size)), with analysis supplying the draft.

### 4. Vendor is repo-specific and secondary

Both repos are near-zero-dependency; the vendor/project blocker share was
negligible. Vendor's value only appears on dependency-heavy code and must be
measured on such a repo (e.g. fzf) before it is judged - it is not the lever
for typical Go code.

## Determination

**>80% complete Big-O for production Go is reachable, and my earlier ~55-60%
ceiling was wrong** - it counted test-code loop noise. Excluding tests,
structural incompleteness is ~0; completeness is bounded almost entirely by
**callee/receiver resolution into the standard library**, which is tractable
because Go calls are statically typed and package-qualified.

The smarter method is two coupled pieces, not "analyze GOROOT and consume it":

1. **An asserted Go stdlib bound table covering both forms** in
   `config/stdlib_complexity/go.yml`:
   - package functions (`fmt.*`, `filepath.*`, `os.*`, `exec.*`, `strconv.*`,
     `strings.*`), and
   - **type methods** (`sync.Mutex`, `sync.WaitGroup`, `*os.File`,
     `os.FileInfo`, `fs.DirEntry`, `bytes.Buffer`, `strings.Builder`,
     `time.Time`, `*flag.FlagSet`).

   Espalier's stdlib analysis supplies the draft known component; a human closes
   the reflection/callback cases with a sound bound. Ranked by
   `unknown_operations` occurrence, ~30-40 entries cover the bulk.

2. **Local/flow receiver type resolution** so `mu`, `info`, `f`, `flags` resolve
   to their stdlib types and pick up (1). This is the dominant gap named in
   `complexity-coverage.md`; for Go it is available from declared/assigned local
   types (or `go/types`/SSA for the hard cases).

With both, the sampled repos project to ~90% (unslop) / ~89% (boobytrap)
complete on production code. Vendor is a later, repo-specific add-on.

This revises the "don't build" of `minimal-call-graph-feasibility.md`, whose
data was Ruby (dynamic dispatch). Go's static typing makes the same lever pay
off very differently.

## Experiment: precomputed stdlib bounds + "trust the known component"

Built `config/stdlib_complexity/go.stdlib.json.gz` (2,412 functions) by running
`espalier -f architecture` over 330 files of the commonly-imported stdlib, then
tested two consumption models.

**1. Propagating stdlib bounds by corpus union gives ~zero uplift.** Analyzing
unslop *together with* the stdlib source left production completeness at
**24% -> 24%**. Because the stdlib is only 38% self-complete (1,172/3,071), its
bounds are themselves `unknown`, and transitive completeness cascades the
incompleteness straight back to the caller. Requiring transitive completeness is
the wrong bar.

**2. "Trust the known component unless a hidden callee can exceed it" reaches
~90%.** For every incomplete function we already emit a known structural
component (`O(1)`, `O(N)`, ...). It is only *wrong* if a hidden callee is
asymptotically larger - which needs FFI (opaque C/syscall/runtime/unsafe),
reflection, or a super-linear callback. Classifying incomplete functions by
whether any blocker is in those danger categories:

| Corpus | incomplete | known component RIGHT | risky: FFI | superlinear | reflection |
|---|---:|---:|---:|---:|---:|
| Go stdlib (worst case for FFI) | 1,708 | **81%** | 18% | 0% | 1% |
| unslop | 92 | **88%** | 11% | 1% | 0% |
| boobytrap | 46 | **83%** | 2% | 15% | 0% |

Combined with the already-complete fraction, **effective trustworthy Big-O is
~88-91%** on all three, and the residual risk is concentrated exactly where you
predicted: FFI, plus a little super-linear-stdlib-in-a-cheap-function
(boobytrap's `sort` usage). This holds on the stdlib itself, the most
FFI-dense Go there is; ordinary application code is safer.

**Caveat - the known component is also sometimes *over*-estimated.** The
analyzer emits garbage for interface-callback and unbounded-recursion functions:
`sort.Sort` -> a nonsensical multivariate blob (should be `O(N log N)`),
`os.MkdirAll` -> `O(2^N)` (should be `O(depth)`). "Trust the known component"
therefore also needs the structural analyzer's recursion/callback handling
tightened, or those cases would be confidently wrong.

## Revised recommendation

The lever for >80% Go is **not** propagating stdlib completeness (0 uplift) and
**not** a name-matched bounds table (fragile keys, self-incomplete source). It
is a **completeness-model change**: report the known component as an
*authoritative, confidence-tiered* answer, and reserve `unknown` for functions
whose blockers are FFI / reflection / unbounded callback. That alone yields
~88-91% trustworthy bounds. Support it with two fixes: (a) an explicit
FFI/reflection boundary tag on facts, and (b) tighter structural handling of
recursion and interface-callbacks so the trusted component is not over-estimated
(`sort.Sort`, `os.MkdirAll`). `go.stdlib.json.gz` remains useful as a reference
for the ~38% of stdlib functions that *are* complete, not as a propagation feed.

## Recommended validation before building

Assert the top ~30 Go stdlib bounds (package fns + type methods) in `go.yml`,
add the local receiver-type resolution, re-run architecture on unslop +
boobytrap + a dependency-heavy repo (fzf), production functions only, and
confirm `time_complete` clears 80%. Build in that order; stop if step 1 alone
does not reach ~65%.

## Reproduction

```sh
espalier -f architecture       -o arch.json    <non-test go files...>
espalier -f unknown_operations -o unknown.json <non-test go files...>
espalier -f architecture -o stdlib.json \
  /usr/lib/go-1.22/src/{fmt,path/filepath,strconv,strings,sort}/*.go  # exclude _test
# then: filter arch nodes to paths not ending _test.go; measure time_complete
```
