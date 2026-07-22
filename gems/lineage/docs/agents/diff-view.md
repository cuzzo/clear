# Risk-Ranked Semantic Diff View

## Status

Implemented through delivery slice 6. This is a Lineage UI feature, not a
replacement for GitHub's Files Changed view. It explains the review risk of a
revision pair using the same line-level coverage, mutation, hazard, and SARIF
evidence already shown in the source view. Assertion observations (slice 7)
and migration of the existing source, dashboard, and architecture routes
(slice 8) remain separately planned work.

## Product decision

Lineage will provide a revision-pinned diff view that answers two questions
before showing code:

1. What meaningful production and test code was added, by language and by
   verification state?
2. Which changed files and symbols deserve review first, and why?

The main presentation is semantic and risk-ranked. It groups changed code by
file and logical source construct rather than reproducing source order. A
separate raw presentation remains available for reviewers who need a normal
patch in source order.

The diff view will be the first canonical screen in a new React + Monaco
frontend. The long-term Lineage UI should move to that frontend, but the
existing Askama source and dashboard screens will migrate incrementally after
the diff view is complete. Rewriting every current screen before delivering
the diff would create a long, high-risk gap without improving its evidence
model.

The view must never make a negative verification claim from missing or
wrong-revision evidence. A missing coverage or mutation artifact is an
evidence gap, not an uncovered line.

## Goals

- Show the normal Lineage source experience in a diff: coverage and mutation
  state, hazards, all SARIF findings, dark-arm overlays, source links, and
  finding detail.
- Rank changed production files by added unverified semantic code, added
  decision complexity, and new tier-1 hazards.
- Give a compact repository and per-language change summary that excludes
  blank lines and delimiter-only lines such as Ruby `end` and `}`.
- Separate added production code from added comments and added test code.
- Split production additions into public and private code, retaining a visible
  `unknown visibility` bucket rather than guessing.
- Show only changed functions and newly introduced type declarations in the
  semantic body. Public functions are risk-sorted; private functions are
  collected at the bottom of each file in one collapsed group.
- Make both inline and side-by-side forms available without changing the
  semantic grouping, score, or evidence.
- Preserve a one-click standard, source-ordered diff for residual lines and
  for reviewers who prefer the conventional patch.
- Work across every language for which Lineage has a Tree-sitter parser, while
  being explicit when semantic classification or visibility is unavailable.

## Non-goals

- Reimplement GitHub review comments, mergeability checks, or code ownership.
- Infer that a line is tested merely because a nearby line or enclosing
  function is tested.
- Treat an artifact ingested for another revision as evidence for the viewed
  revision.
- Hide deleted code. Deletions appear in the raw diff and in a compact
  removal summary, but do not receive head-revision coverage claims.
- Reorder code inside an expanded function body. Only the list of semantic
  groups is risk-ranked; a group's own patch retains normal source order.
- Add assertion counting in the first implementation. The UI reserves that
  field and labels it unavailable until a test-observation producer exists.

## Revision and evidence contract

Every diff is between two immutable, resolved Git object IDs:

```text
/diff?base=<full-oid>&head=<full-oid>&presentation=semantic&layout=split
```

The route accepts a branch or abbreviated revision only as input. The server
resolves it once, redirects to full object IDs, and uses those IDs everywhere:
source reads, diff generation, evidence lookup, cache keys, links, and API
responses. `HEAD` is therefore never persisted as a symbolic scope identity.

The default pair is the merge base of the selected head and its first parent,
then the selected head. The UI offers an explicit base selector for comparison
against another branch or commit. Working-tree content is out of scope for the
first release because it has no immutable evidence identity. A later explicit
`worktree` mode may be added, but it must carry an unambiguous dirty-state
banner and may not reuse commit-scoped coverage or SARIF as if it were fresh.

For an evidence family to inform a head line, its artifact scope must match the
resolved head OID and its selected corpus/test-set identity. The same rule
applies independently to coverage, mutation, hazards, and SARIF. The API
returns an availability state per family:

| State | Meaning | UI treatment |
| --- | --- | --- |
| `exact` | Artifact matches the viewed revision and scope. | May affect a verification category or score. |
| `stale` | Artifact exists, but is for another revision or incompatible scope. | Render dimmed with its revision; never count it as coverage or a new finding. |
| `missing` | No artifact exists for that family. | Show `unknown`; never call it uncovered. |
| `partial` | Artifact declares incomplete selection or attribution. | Show the known observations and an incomplete banner; do not produce a complete negative aggregate. |

This view reads event ledgers and revision-scoped SARIF rows. It must not use
the mutable `logical_units.current_*` cache as the source of truth, since that
cache can describe a later commit.

## Terms and classifications

### Source roles

Each changed file has one source role at the head revision:

| Role | Included in production headline | Included in test headline |
| --- | ---: | ---: |
| `production` | yes | no |
| `test` | no | yes |
| `generated` / `vendor` | no, shown separately | no |
| `documentation` | no | no |
| `unknown` | no, shown separately | no |

The role classifier is shared infrastructure, not a diff-only filename check.
It combines repository configuration, language conventions, and path rules;
repository configuration wins. For example, `test/`, `spec/`, `*_test.go`, and
`*_spec.rb` are conventional test evidence, but a configured production path
must override a misleading filename. Generated and vendored code remain
available in the raw diff, with provenance visible, but cannot dominate the
production risk queue.

### Meaningful added lines

The summary counts only added (`+`) head-side lines. Each added line is parsed
with the head revision's Tree-sitter grammar and classified as one of:

| Class | Counts as production/test code LoC | Counts as comment LoC |
| --- | ---: | ---: |
| blank | no | no |
| comment-only | no | yes |
| structural-only | no | no |
| semantic code | yes | no |
| code with trailing comment | yes | no |

`structural-only` means a line contains only delimiters or syntactic closure:
Ruby `end`, a standalone `}`, `{`, `)`, `]`, or an equivalent grammar-specific
delimiter. A control keyword with semantic force, such as `else`, `catch`, or
`finally`, remains code when the language grammar represents it as a control
node. This is deliberately AST/token based, not a regex that strips braces or
searches for comments.

Comment-only lines are reported as **added comments**, separate from both the
public and private code totals. A trailing comment does not double-count the
line as comment LoC; an optional later detail may report trailing-comment
characters separately.

If a changed language has no trustworthy parser or the parse contains an
unrecoverable error across a changed hunk, the view reports `semantic
classification unavailable` for that file and links to the raw diff. It must
not manufacture code/comment/structural totals from text heuristics.

### Visibility

Visibility is derived from parsed declaration facts and language adapters,
never from a display-name convention alone. The presentation has three stable
buckets:

- **public**: externally callable/exported under the language's normal module
  or type rules;
- **private**: not externally callable from the declared API boundary;
- **unknown**: the adapter cannot establish visibility.

Language-specific access levels such as Rust `pub(crate)`, Java package access,
and TypeScript non-exported declarations are rendered with their native label
but are included in the private/non-public aggregate. Ruby visibility follows
the parsed `private`/`protected` context, not merely underscore naming. Go
uses exported declaration semantics, and Zig uses `pub`. A symbol with unknown
ownership or visibility never silently becomes public or private.

### Verification slices

Each meaningful added production line belongs to exactly one displayed primary
verification slice, derived from exact head line evidence in this order:

1. **covered + mutant killed**: execution evidence is positive and one or more
   attributed mutants were killed by the selected test corpus;
2. **covered**: execution evidence is positive, the line is not partial, and
   no killed-mutant evidence is available;
3. **partially covered**: execution reached the line but branch/arm evidence is
   partial;
4. **not covered**: an exact, complete coverage artifact explicitly reports no
   execution for the line;
5. **unknown**: coverage is missing, stale, incomplete, or the line is outside
   the selected coverage corpus.

The first four are the requested headline slices. `unknown` is an additional
truthfulness bucket and is always displayed when nonzero. A partially covered
line that also has a killed mutant is placed in `covered + mutant killed`, with
a `partial` sub-count and badge retained in the detail. Thus the four primary
totals remain disjoint without discarding evidence.

Mutant status is never inferred from a function-level total. A line receives
the strongest slice only when the mutation fact is attributed to that line or
to a source span that contains it under the selected corpus identity.

## Risk model

Risk is a transparent review ordering, not a probability of a defect. Version
one uses only newly added production risk so pre-existing legacy debt cannot
hide a risky small patch.

For a file `f`:

```text
U(f)  = meaningful added production lines with exact "not covered" evidence
P(f)  = meaningful added production lines with exact partial coverage
DC(f) = sum(max(0, head_decision_complexity(symbol)
                 - base_decision_complexity(matched_symbol)))
H1(f) = newly introduced active tier-1 hazards/findings anchored in f

risk(f) = 1.0 * U(f) + 0.5 * P(f) + 2.0 * DC(f) + 8.0 * H1(f)
```

The same formula is used for a public function, a new type declaration, and
the private aggregate. `U`, `P`, `DC`, and `H1` are always shown beside the
score; no hidden severity multipliers are allowed. Ties sort by `H1`, then
`U`, then added meaningful lines, then path/name for deterministic output.

`DC` is a portable AST decision-point delta, not a claim that Lineage has
proven a full Big-O bound. It counts the language adapter's control-decision
nodes for the construct at each revision. A new function is compared with the
language baseline complexity of one. This independent metric avoids depending
on the availability of a Decomplex SARIF result while remaining explainable.

`H1` means an active head finding with tier `1` in its SARIF properties or
provider contract that is new relative to base. A finding is new when its
stable fingerprint/natural identity does not exist in base, or when its
anchored span was introduced by the patch and no base identity can be mapped.
Tier interpretation is policy-versioned and rendered in the UI. Untiered
findings still appear in SARIF overlays but do not affect `H1` until a policy
explicitly maps them.

Lines with unknown coverage do not contribute to `U`; the file instead carries
an evidence-gap badge. This prevents a repository with no coverage upload from
being presented as confidently fully uncovered. A future policy may rank
evidence gaps separately, but it must retain that label and cannot fold them
into `not covered`.

The weights live in a named `diff-risk/v1` policy with tests for the complete
formula. Calibration changes require a new policy version and a changelog
entry, so saved URLs and CI summaries remain interpretable.

## Change inventory, configuration, and dependencies

Before the production/test language cards, the page shows a repository-wide
inventory of the patch. This is intentionally a change summary, not a second
risk score:

```text
Change inventory
  11 directories changed · 27 files changed · 9 added · 2 deleted · 1 renamed
  Production source  14 files   +184 meaningful code   +23 comments
  Test source         5 files   +91 meaningful code    assertions: unavailable
  Configuration       4 files   Cargo.toml, Gemfile, .github/workflows/ci.yml, .gitignore
  Documentation       2 files   +88 Markdown lines
  Generated / locks   2 files   Cargo.lock, Gemfile.lock

Dependency changes
  Cargo.toml         +serde_json 1.0  (direct, runtime)
  Gemfile            +rack ~> 3.1   (direct, runtime)
  package.json       no declared dependency changes
```

`directories changed` is the number of distinct normalized parent directories
of changed files. The root is displayed as `.` and counts once. `files changed`
counts a rename once, not once at each path. Added, deleted, renamed, copied,
and modified counts are derived from the rename-aware Git patch rather than
from two directory listings.

### File categories

Every changed file receives a display category in addition to its source role:

| Category | Purpose |
| --- | --- |
| production source / test source | Feeds the language and meaningful-LoC summaries. |
| configuration | Shows operational or build behavior changes separately from code. |
| dependency manifest | Configuration with a parser-backed declared-dependency adapter. |
| lockfile | Generated/resolved dependency state; shown separately from declared dependencies. |
| documentation | Markdown and configured documentation formats, reported separately. |
| generated / vendor | Visible but excluded from production-risk ranking by default. |
| other / binary | Visible in the inventory and raw diff; no semantic LoC claim. |

Documentation initially means `.md`; repository configuration can extend it to
formats such as `.mdx`, `.rst`, and `.adoc`. The requested default inventory
therefore always contains a dedicated Markdown count.

`generated` is not synonymous with a lockfile. Lockfiles are a first-class
category because they can represent a consequential resolved dependency update.
Generated classification combines configured paths, known build-output paths,
generated-file markers, and repository overrides. A generic directory name
such as `build/` is never enough by itself to hide a file from review. The
inventory makes every excluded/generated file expandable and links it to the
raw diff.

### Configuration catalog

Add a declarative `ConfigCatalog` owned by Lineage, with repository overrides.
It classifies a path before attempting to parse its contents. The initial
catalog must cover every language with a Lineage Tree-sitter adapter, plus
repository/CI configuration:

| Ecosystem / role | Configuration and manifest candidates | Lock / generated candidates |
| --- | --- | --- |
| Repository / CI | `.gitignore`, `.gitattributes`, `.editorconfig`, `.rspec`, `.ruby-version`, `Dockerfile`, `compose*.yml`, `.github/workflows/**/*.yml`, `.github/actions/**`, supported CI files | generated CI artifacts only when configured |
| Ruby | `Gemfile`, `*.gemspec`, `Rakefile`, `.rubocop*.yml`, `config/**/*.yml` | `Gemfile.lock` |
| Rust | `Cargo.toml`, `.cargo/config.toml`, `rust-toolchain.toml` | `Cargo.lock` |
| JavaScript / TypeScript | `package.json`, `tsconfig*.json`, `eslint.config.*`, `.eslintrc*`, `vite.config.*`, `webpack.config.*` | `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `bun.lockb` |
| Python | `pyproject.toml`, `requirements*.txt`, `setup.cfg`, `setup.py`, `Pipfile`, `tox.ini`, `noxfile.py` | `poetry.lock`, `uv.lock`, `Pipfile.lock` |
| Go | `go.mod`, `.golangci.*`, `Makefile` | `go.sum` |
| Zig | `build.zig`, `build.zig.zon`, `zig.mod` when present | Zig package-resolution files when an ecosystem defines them |
| C / C++ | `CMakeLists.txt`, `*.cmake`, `meson.build`, `Makefile`, `vcpkg.json`, `conanfile.*` | CMake/build output only when tracked and configured |
| C# | `*.csproj`, `*.fsproj`, `*.sln`, `Directory.Build.*`, `NuGet.config` | `packages.lock.json` |
| Java / Kotlin | `pom.xml`, `build.gradle`, `build.gradle.kts`, `settings.gradle*`, `gradle.properties`, `gradle/libs.versions.toml` | Gradle dependency-lock files and wrapper-generated metadata when tracked |
| Swift | `Package.swift`, `.swiftpm/**` configuration | `Package.resolved` |
| PHP | `composer.json`, framework configuration files | `composer.lock` |
| Lua | `*.rockspec`, `.luacheckrc`, `config.lua` when configured | LuaRocks lock/resolution files when present |

The catalog is deliberately data-driven so a new language adapter adds its
configuration rules in one audited place. It supports monorepos: matching is
performed per path and nearest manifest root, not only at repository root.
Repository configuration can add custom manifests, change a category, or
disable an overly broad rule.

The shipped override file is revision-scoped: Lineage reads
`.lineage/diff.toml` from the selected immutable head revision. It supports
auditable exact-path and directory-prefix source-role overrides; overrides win
over catalog and convention classification:

```toml
[[overrides]]
prefix = "services/generated/"
role = "generated"

[[overrides]]
path = "spec/production_contract_spec.rb"
role = "production"
```

Valid roles are `production`, `test`, `documentation`, `configuration`,
`generated`, `lockfile`, and `other`. Absolute paths, traversal components,
empty entries, and unknown roles are ignored. The longest matching prefix
wins; an exact path wins over any prefix.

### Dependency changes

The dependency panel reports **declared** dependency changes by manifest path,
then optionally related resolved changes from its lockfile. It distinguishes
direct from transitive/resolved dependencies and runtime from development/test
scope when the ecosystem supplies that information. A dependency row contains:

```text
manifest path · ecosystem · package identity · change (added/removed/changed)
old requirement/resolution · new requirement/resolution · dependency scope
```

For example, adding `serde_json` to a nested `Cargo.toml` is shown under that
exact manifest, not under an undifferentiated repository dependency count.
Changing only `Cargo.lock` is shown as a resolved/lock change, not falsely as a
new direct dependency.

There is no reliable single dependency library for every supported ecosystem:
`Gemfile`, Gradle, `Package.swift`, CMake, `build.zig`, and many Lua/C++ build
files are executable or extensible languages. The implementation must never
extract dependencies by regular expression from those files. It instead uses a
`DependencyAdapter` per manifest family:

```rust
trait DependencyAdapter {
    fn matches(&self, path: &RepoPath) -> bool;
    fn extract(&self, revision: &RevisionBlob) -> DependencyExtraction;
}
```

`DependencyExtraction` is one of `exact`, `partial`, `unsupported`, or
`invalid`. Every non-`exact` result is rendered as an **unknown package-file
change** with the exact manifest path and a raw-diff link. `unsupported` means
the UI does not claim that its dependencies are unchanged; `invalid` includes
the parser diagnostic without hiding the package-file change.

The first exact adapters should cover static, high-confidence formats:

- `Cargo.toml`/`Cargo.lock` through a TOML-aware Cargo adapter; evaluate
  `cargo_metadata` for workspace/resolution metadata and use a structural TOML
  parser for revision blobs;
- `package.json` and npm/pnpm/yarn manifests through JSON parsing;
- `pyproject.toml` and requirements files through TOML/PEP-508-aware parsing;
- `go.mod`/`go.sum` through the official Go module parser or a tested adapter;
- `composer.json`/`composer.lock`, `Package.resolved`, XML `.csproj`, and Maven
  `pom.xml` through their structured JSON/XML formats.

Dynamic formats enter only after a dedicated adapter can prove its behavior:
Bundler/Ruby for `Gemfile`, Gradle/Kotlin, SwiftPM manifests, Zig build files,
CMake/Meson/Conan, and LuaRocks. Calling an ecosystem tool in a temporary
checkout is allowed only as an explicit, bounded, opt-in resolver with no
network access and clear `partial` output; it is never a hidden prerequisite
to rendering a diff.

### Required discovery task

Before implementing the catalog, run a dependency/configuration discovery
spike with these deliverables:

1. Enumerate all current Lineage-supported languages from the parser registry
   and map real validation-corpus repositories to their manifests, lockfiles,
   CI files, documentation, and generated paths.
2. Compare maintained parser libraries or official parsers for each structured
   manifest family, including whether they parse revision blobs, preserve
   source location, support workspaces/monorepos, and expose dependency scope.
3. Mark executable/dynamic formats as exact, partial, or unsupported based on
   fixtures—not on apparent textual simplicity.
4. Produce a versioned catalog fixture with positive and negative path cases:
   `.github/workflows/ci.yml`, `.gitignore`, `.rspec`, `Gemfile.lock`, nested
   `Cargo.toml`, generated `package-lock.json`, Markdown docs, and paths that
   merely resemble configuration names.
5. Select the first adapter set only after this comparison. Prefer a maintained
   library or official parser where it fits; otherwise expose the file change
   without dependency claims.

## Repository and language summary

The page begins with a revision banner and one summary card per language. It
does not collapse Ruby, Zig, Go, and other languages into one opaque total.

```text
base 7aa1...  ->  head a93f...        Semantic view | Raw diff

Production additions
  Ruby  34 meaningful lines     public: 22   private: 12   comments: 8
        9 covered+killed | 7 covered | 4 partial | 10 not covered | 4 unknown
  Zig   18 meaningful lines     public: 18   private: 0    comments: 2
        12 covered+killed | 3 covered | 0 partial | 3 not covered

Test additions
  Ruby  26 meaningful lines | assertions: unavailable (test observations not ingested)
  Zig    9 meaningful lines | assertions: unavailable (test observations not ingested)
```

The production table is sliced first by language and then by visibility. It
also exposes the exclusive verification slices above. Comments are a separate
row, never a visibility bucket. Test additions are per language and include
meaningful test code plus comment LoC; the future assertion value is shown as
`unavailable`, never `0`, until the producer is implemented.

The eventual producer contract is `test-observations/v1`, revision-scoped and
language-neutral, with at least test file, test identity, assertion count,
framework, and corpus identity. The diff API already has nullable fields for
it, but the first implementation does not create, estimate, or backfill
assertions.

Deleted meaningful code and deleted comments are shown in a secondary
`removals` disclosure. They are useful review context but do not inflate the
added-code risk score.

## File ordering and layout

Files are shown in descending `risk(f)`, with the four score components
visible. A file header includes its role, language, rename status, meaningful
additions, verification slice bar, new tier-1 hazard count, all-SARIF count,
and an evidence freshness indicator.

```text
1. gems/lineage/src/ui/diff.rs                         risk 31.5
   production · Rust · +28 code · +4 comments
   12 uncovered + 3 partial + complexity +2 + 2 new tier-1 hazards
   [SARIF 6] [coverage exact] [mutation exact]

   Public changes, highest review risk first
   ▸ render_diff_file       +1 complexity · +1 T1 · +14 code
                              4 killed | 2 covered | 2 partial | 6 uncovered
   ▸ DiffSummary::from      +0 complexity · +0 T1 · +6 code
                              3 killed | 3 covered
   ▸ new struct DiffPlan    +1 complexity · +1 T1 · +8 code
                              5 killed | 1 partial | 2 uncovered

   Other changed lines: 5 code, 2 comments, 0 hazards   [open raw file diff]

   ▸ Private changes (3 functions, 19 code, +2 complexity, +0 T1)
                              8 killed | 4 covered | 1 partial | 3 uncovered
```

### Semantic groups

For each non-deleted file, the semantic view creates these ordered groups:

1. changed public functions and methods, sorted by risk descending;
2. newly introduced classes, modules, structs, enums, unions, interfaces, and
   equivalent type declarations, also sorted by risk descending;
3. a compact **Other changed lines** summary immediately above private changes;
4. one **Private changes** group containing every changed private/non-public
   function, regardless of original line order.

Every public function and new type declaration is collapsed initially. Its
summary includes added decision complexity, new tier-1 hazards, meaningful
added code lines, and the five verification counts. Activating the existing
function-collapser affordance expands its rendered patch in the selected
layout. Existing type declarations are not duplicated merely because a method
inside them changed. For a new type, its declaration is the outer collapsed
group and changed member functions are nested within it.

The private group is collapsed initially and has **one aggregate summary
block**. Opening it reveals its changed private functions, each still collapsed
until selected. Private functions are deliberately at the bottom of the file,
even when their source precedes a public function. This is a review order, not
a claim about source order.

Residual added code—top-level statements, imports, annotations, macro
invocations, changed constants, and any code that cannot be safely assigned to
a displayed construct—is not scattered through the semantic view. The
**Other changed lines** summary links to:

```text
/diff?base=<oid>&head=<oid>&presentation=raw&path=<head-path>&focus=residual
```

The raw view is a standard source-ordered patch for that file. It preserves all
context, including whitespace, comments, closures, deletions, and unassigned
lines. It is also the fallback for binary files, parse failures, and language
adapters without semantic support.

Deleted functions and deleted types appear as compact, dimmed removal groups in
the raw view and in the file's removal disclosure. The semantic risk queue
focuses on head-side additions, so deleted-only files sort after files with
positive risk.

### Inline and side-by-side code

The layout control is visible at the revision banner and each setting is stored
in local storage and in the URL:

```text
layout=inline | split
```

- **Split** is the default on a sufficiently wide viewport. Base and head line
  numbers align in a two-column patch; head lines carry current coverage,
  mutation, hazard, and SARIF rails. Base findings are visible but visually
  muted as baseline evidence.
- **Inline** is the default on narrow screens and shows additions and removals
  in one column with the same line annotations.

Changing layout does not recompute grouping, ordering, visibility, or risk.
Expanding a semantic group opens the same group in the newly selected layout.
The source view's existing fold model should be extracted into a shared,
semantic `FoldControl` renderer rather than copied as a second CSS-only
implementation.

## SARIF and source evidence

The head side renders every persisted SARIF finding that is exact for the
selected head scope: Decomplex, SlopCop, Boobytrap, Nil-Kill, Espalier,
SQL-COV, Test Miser, native lint, and third-party SARIF. Finding detail keeps
tool, rule ID, level, category, tier, message, source span, artifact scope,
and source link. Existing layer toggles carry into the diff page.

Findings are compared by the normalized SARIF natural identity:

```text
source + tool + rule + fingerprint + mapped logical/source identity
```

The UI labels findings as `new`, `persisted`, `moved`, `resolved`, or `stale`.
Only exact `new` tier-1 findings contribute to risk. A persisted or stale
finding is still important context, but it must not masquerade as a newly
introduced hazard.

Coverage and mutation rails apply only to the corresponding head-side source
span. If a mutation fact covers a span rather than a single line, the detail
discloses that span attribution. A source-range mismatch, unknown test corpus,
or incomplete attribution produces an evidence badge rather than a green or
red verification claim.

## Backend design

### Diff plan

Add a pure Rust `diff` module that produces an immutable `DiffPlan` before any
HTML is rendered:

```rust
struct DiffScope {
    base_oid: String,
    head_oid: String,
    evidence_scope: EvidenceScopeFingerprint,
    risk_policy: RiskPolicyVersion,
}

struct DiffPlan {
    scope: DiffScope,
    availability: EvidenceAvailability,
    inventory: ChangeInventory,
    language_summaries: Vec<LanguageSummary>,
    dependency_changes: Vec<DependencyChange>,
    files: Vec<DiffFile>,
}
```

`ChangeInventory` owns file/directory counts, category totals, configuration
paths, and generated/lockfile disclosures. `DiffFile` contains the
rename-aware base/head paths, source role, display category, language, raw
hunks, meaningful-line classification, exact line evidence, finding delta,
semantic groups, and score decomposition. `DiffGroup` has a stable kind
(`public_function`, `new_type`, `residual`, `private_aggregate`, `removal`),
source ranges, visibility, totals, and a render-independent ordered patch.

The module uses `GitProvider`/`git2` to obtain a rename-aware patch and blob
contents. It never invokes a shell with a user-provided revision or path.
Paths use the same repository-relative validation as the source controller.

### Symbol matching and complexity delta

Symbols are parsed at both revisions. Matching proceeds in this order:

1. Lineage logical-unit identity when a revision-stable unit mapping exists;
2. rename-aware file identity plus declaration kind/qualified name;
3. bounded structural fingerprint of the declaration header and AST shape.

Ambiguous matches are left unmatched and labelled `new/unknown`, rather than
borrowing base complexity from a similarly named sibling. The new construct's
complexity is then measured against the language baseline.

The initial decision-complexity adapter is intentionally small and
cross-language: it counts parser-recognized branching, loop, boolean-short
circuit, pattern/exception arm, and conditional-expression nodes according to
a per-language table. It is tested against Ruby, Zig, Go, Rust, Python,
JavaScript/TypeScript, Java, and Kotlin fixtures. A richer Decomplex metric may
be shown as supplementary SARIF detail but must not silently replace this
versioned delta.

### Evidence resolver

Introduce a revision-scoped `DiffEvidenceResolver` with batch APIs for all
changed head paths and ranges. It resolves:

- line and branch coverage;
- named test exposure and killed-mutant attribution;
- active hazards;
- persisted SARIF findings and normalized finding identity;
- source-role configuration and parser/visibility capability.

The resolver returns `exact`, `stale`, `missing`, or `partial` independently
for each evidence family. It batch-loads by changed path/range; there must be
no per-line SQLite query. A later materialized cache may be added only after
profiling, keyed by `(base_oid, head_oid, evidence_scope_fingerprint,
risk_policy_version)`, and invalidated when the matching artifact ledger
changes.

### Routes and API

Axum remains the single local server and owns the APIs. `/diff` serves the
embedded React application; the application fetches typed plans from:

```text
GET /diff
GET /api/diff/plan
GET /api/diff/file
```

The JSON endpoints are the contract for the React frontend, fixtures, and
future editor integrations. All endpoints return resolved OIDs, evidence
availability, policy version, and enough totals to reproduce the visible score.
They use a versioned envelope, for example `{"api_version":"v1","data":...}`.
The Rust request/response structs are the schema source of truth and generate
strict TypeScript declarations during the UI build; TypeScript must not carry a
hand-maintained shadow of these models.

The source controller gains links from file history and source symbols into the
appropriate diff group. The dashboard can later add a `Review this change`
entry point, but that is not required for the initial slice.

## Frontend decision

### Decision: React + Monaco now, incremental application migration

The existing Rust-rendered UI is successful as a local source browser, but it
is the wrong long-term center for this product. The semantic diff alone needs
revision selectors, URL-synchronised state, risk sorting, private group
aggregation, split/inline switching, source/SARIF decorations, lazy code
models, and later filtering and review interaction. Adding those behaviors to
Askama templates, CSS checkbox state, and a growing global JavaScript file
would turn the UI into an implicit frontend framework without the testing or
type safety of one.

Create a strict TypeScript React application at `gems/lineage/ui/` now. React
is the application shell and semantic review surface; Monaco is the code and
raw-diff renderer. Do not use Monaco to lay out the risk-ranked page itself:
React owns summary cards, file ordering, collapsed groups, controls, and
accessibility; an expanded group mounts a Monaco `DiffEditor` for its code.
This separation prevents a large editable-editor abstraction from swallowing
the review model.

The destination is a full React/Monaco Lineage UI. The migration is a
strangler, not a big-bang rewrite:

1. Ship `/diff` as React/Monaco with no duplicated Askama implementation.
2. Move the current source view to React/Monaco once it reaches feature parity
   for line layers, history, outlines, and fold behavior.
3. Move dashboard and architecture screens as their interaction needs justify
   it.
4. Remove the old Askama UI only after parity tests and user-visible routes
   have migrated.

No new feature should be added to the old template renderer once a React
equivalent route exists. This gives the team one frontend direction without
blocking the diff feature on a wholesale port.

### Frontend project and build boundary

The project is a real, independently testable frontend package, not TypeScript
sprinkled into `src/ui/assets/`:

```text
gems/lineage/ui/
  package.json
  pnpm-lock.yaml
  tsconfig.json
  vite.config.ts
  src/
    api/
    components/
    diff/
    source/
    generated/            # Rust-generated API declarations; not hand-edited
  tests/
  dist/                   # generated; not hand-edited
```

Use React, strict TypeScript, Vite, `monaco-editor`, and
`@monaco-editor/react`; load Monaco lazily so the dashboard shell does not pay
for it. Use a lockfile and deterministic `pnpm --frozen-lockfile` CI. Prefer
small React state local to each route: the URL is the source of truth for
revisions, path, selected group, and layout; a thin typed fetch/cache layer
owns API requests. Do not add a global state-management framework unless a
second independent screen demonstrably needs shared client state.

An explicit `cargo xtask ui build` (or equivalent repository tool) first
generates TypeScript declarations from Rust API types, then runs the frontend
build, and finally places hashed static assets where the Rust binary embeds
them. Release CI runs this before `cargo build`; development commands report a
clear missing-assets error with the exact build command. Cargo must not
silently run a package-manager install as a build-script side effect.

Rust owns routing, repository/path safety, revision resolution, evidence joins,
and the versioned schema. The frontend owns rendering, local interaction,
virtualization when required, and accessible focus management. The shipped
binary embeds the built assets and serves them locally; it never requires Node,
a dev server, or an external CDN at runtime. Contract tests serialize Rust
`DiffPlan` fixtures and validate both TypeScript type generation and runtime
response decoding in the frontend.

This is the appropriate Tokio/Axum boundary: the Rust service remains a
single-binary, local-first authority for I/O and integrity, while an isolated
static client provides the interaction model. It is substantially less risky
than attempting to make the existing HTML/CSS renderer behave like React, and
less wasteful than porting the current UI wholesale before the new review flow
has proven itself.

### Monaco responsibilities

- An expanded semantic function/type group creates a read-only Monaco
  `DiffEditor` with the base and head text for only that group. The layout
  toggle maps directly to Monaco's side-by-side setting; no second diff engine
  is introduced.
- The raw file view creates one read-only `DiffEditor` for the selected file,
  preserving conventional source order and full context.
- Head-side coverage, partial coverage, mutant-killed state, hazards, and all
  exact SARIF findings are converted from `DiffPlan` spans into Monaco
  decorations, glyph margins, overview-ruler markers, and hover/peek detail.
  Base-side evidence is visually muted and always labelled with its revision.
- Collapsed summaries are ordinary React buttons with `aria-expanded`; Monaco
  instances mount only after expansion and dispose on collapse or navigation.
  This avoids creating an editor per changed symbol and gives large diffs a
  bounded memory cost.
- The first release does not make code editable. Any future fix/apply workflow
  is a separate security and provenance design.

## Accessibility and usability

- Every collapsed symbol/type/private aggregate uses a React button with an
  explicit label, counts, `aria-expanded`, and an accessible relationship to
  its controlled patch; it is keyboard operable without pointer hover.
- Color is supplementary. Verification states, new hazards, stale evidence,
  and risk components have text labels and icons with accessible names.
- Layout controls are a labelled radio group, retain focus on switch, and do
  not reset opened groups.
- URLs carry the selected revisions, presentation, layout, path, and optional
  symbol anchor, so a review finding can be shared exactly.
- Large diffs are paged by file after a deterministic top-risk initial window;
  the raw file link always remains available.

## Test plan

The feature is correctness-sensitive because it makes negative verification
claims. Required tests include:

1. **Revision identity:** symbolic refs resolve to immutable OIDs; a stale
   coverage/SARIF artifact is shown as stale and cannot affect an exact head
   total.
2. **Meaningful LoC:** Ruby `end`, Zig/Go/Rust braces, blanks, comment-only
   lines, trailing comments, and control keywords are classified correctly.
3. **Language fixtures:** Ruby, Zig, and Go are mandatory end-to-end fixtures;
   Rust and TypeScript are required before their language cards are declared
   supported. Unsupported/parse-error files fall back to raw diff without
   invented totals.
4. **Inventory and catalog:** directory/file/rename counts are stable; every
   catalog row has positive and negative fixtures; Markdown, `.gitignore`,
   `.rspec`, `.github/workflows`, manifests, and common lockfiles are reported
   separately from source code.
5. **Dependencies:** exact adapters report additions/removals/requirement
   changes under the correct manifest path; lock-only changes are not reported
   as direct additions; dynamic/unsupported formats visibly become unknown
   package-file changes.
6. **Source role and visibility:** public/private/unknown cases for at least
   Ruby, Zig, Go, and TypeScript; generated and test paths never inflate the
   production headline.
7. **Verification slices:** each primary slice is exclusive; partial plus
   killed retains a partial detail; missing, incomplete, out-of-corpus, and
   stale evidence become `unknown`, never `not covered`.
8. **Risk math:** fixtures pin every `diff-risk/v1` component, zero/negative
   complexity deltas, tier-1 new versus persisted finding behavior, and stable
   tie ordering.
9. **Grouping:** public functions are risk-sorted, all private functions occur
   in exactly one bottom aggregate regardless of source order, new type groups
   are collapsed, and residual lines link to the source-ordered raw diff.
10. **SARIF:** every tool family renders in the head overlay; new/persisted/
   moved/resolved/stale labels survive renamed files and span changes.
11. **Layouts:** inline and split render the same groups and metrics; keyboard
   expansion, Monaco decorations, and URL anchors work in both forms.
12. **Frontend contract:** generated TypeScript declarations are current, API
    version mismatches fail visibly, and React route tests exercise loading,
    missing/partial evidence, layout persistence, and unmount/disposal of
    Monaco instances.
13. **Scale and safety:** a generated large-diff fixture verifies bounded query
    count, response budget, HTML escaping, invalid path rejection, and no
    external command interpolation.

## Delivery slices

1. Create `gems/lineage/ui` with strict TypeScript, React, Vite, Monaco, the
   generated Rust API contract, and embedded-asset build tooling. Ship a small
   route smoke test before any complex UI is added.
2. Add revision-pinned diff parsing, source-role classification, typed plan
   structures, change inventory, configuration-catalog discovery fixtures, and
   raw per-file diff APIs. No risk claims yet.
3. Complete the configuration/dependency discovery spike and implement only
   its selected exact adapters, with explicit unsupported states for the rest.
4. Add Tree-sitter meaningful-line classification, language/role summary, and
   the `unknown` evidence state. Cover Ruby, Zig, and Go first.
5. Add batch revision evidence resolution, all-SARIF overlays, verification
   slices, and the versioned risk formula.
6. Implement the React semantic review page: inventory, language/config/
   dependency summaries, risk-ranked groups,
   private aggregate behavior, and lazy Monaco inline/split editors.
7. Add assertion observations when a trustworthy producer exists; until then
   keep the explicit unavailable state.
8. Migrate source view, dashboard, and architecture view to React/Monaco in
   separately testable parity slices; remove Askama only after route parity.

### Delivered scope

- [x] React/Vite/Monaco project, Rust-generated API declarations, embedded
  hashed assets, and revision-pinned diff routes.
- [x] Rename-aware inventory, semantic line classification, source roles,
  language summaries, AST grouping, residual raw links, and the published
  `diff-risk/v1` formula.
- [x] Broad configuration/lockfile catalog, parser-backed static dependency
  adapters, and conservative unknown package-file results for dynamic or
  invalid manifests.
- [x] Revision/corpus-scoped coverage and mutation slices, exact line rails,
  stale/partial/missing evidence states, and risk-ranked semantic Monaco
  review in inline or split layouts.
- [x] Complete two-sided SARIF lifecycle comparison (`new`, `persisted`,
  `moved`, and `resolved`), stale artifact detection, and all head findings as
  Monaco overlays.
- [x] Revision-scoped repository source-role overrides and deterministic
  URL-backed large-diff file pagination.
- [ ] Assertion observations require the separate `test-observations/v1`
  producer; the UI deliberately continues to show `unavailable` rather than
  inventing a count.
- [ ] Existing source/dashboard/architecture routes remain on the planned
  incremental React migration path and are not part of the delivered diff
  view.

## Acceptance criteria

- A reviewer can open a stable base/head URL and see every changed production
  file ordered by the published formula.
- Ruby, Zig, Go, and any subsequently declared language show separate
  production/test/comment summaries whose code LoC excludes whitespace and
  closure-only lines.
- The page reports changed directories and files plus separate configuration,
  Markdown documentation, generated/lockfile, and parser-backed dependency
  changes without mistaking a dynamic manifest or lock-only update for a new
  direct dependency.
- The page never labels missing, stale, incomplete, or out-of-corpus evidence
  as uncovered or mutant-killed.
- Every public changed function and new type has a collapsed metric summary;
  all private changed functions appear in one collapsed group at the bottom of
  the file; residual lines link to a conventional raw diff.
- Both Monaco diff layouts show the same exact SARIF and verification evidence,
  and the raw view remains available from the same revision-pinned API.
- The implementation is covered by adversarial multi-language fixtures and
  does not require a Node runtime in the shipped Lineage binary.
