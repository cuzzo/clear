# Ecosystem SARIF into Lineage

## Purpose

Use mature language analyzers as the default source of defect findings, store
their SARIF in Lineage, and reserve first-party FactMine/Decomplex analysis for
facts or findings that external tools do not provide.

This is an ingestion guide, not a claim of equivalent analyzer coverage. A
tool supporting a language does not mean it detects every alias, iterator,
lifetime, or concurrency hazard in that language.

The architecture decision and hazard assessment live in
`gems/fact-mine/docs/agents/aliasing-hazards.md`.

## One Lineage Import Contract

Lineage already accepts any SARIF 2.1.0 file with a `runs` array. Generate the
artifact from the same checkout/commit represented by the Lineage database,
keep result paths relative to the repository when possible, and import each
tool/language under a distinct source bucket.

From the repository being analyzed:

```sh
COMMIT=$(git rev-parse HEAD)

cargo run --manifest-path /path/to/litedb/gems/lineage/Cargo.toml -- \
  ingest-sarif \
  --db lineage.db \
  --repo . \
  --input tmp/lineage-sarif \
  --source ecosystem \
  --commit "$COMMIT" \
  --replace
```

For repeatable CI, prefer one invocation per stable source bucket:

```sh
cargo run --manifest-path /path/to/litedb/gems/lineage/Cargo.toml -- \
  ingest-sarif --db lineage.db --repo . \
  --input tmp/lineage-sarif/codeql-ruby.sarif \
  --source codeql-ruby --commit "$COMMIT" --replace
```

`--replace` deletes prior findings for the same source and commit before
inserting the new artifact. Directory inputs are recursive; non-SARIF JSON is
ignored. The command reports artifact, finding, skipped-file, and
skipped-result counts. A nonzero skipped count must be reviewed before calling
the import complete.

For temporary local viewing without persistence:

```sh
cargo run --manifest-path /path/to/litedb/gems/lineage/Cargo.toml -- \
  ui --db lineage.db --repo . \
  --overlay tmp/lineage-sarif/codeql-ruby.sarif
```

## Broad Baseline: CodeQL

CodeQL is the broadest single semantic baseline for FactMine's language set.
As of this assessment it covers C/C++, C#, Go, Java/Kotlin, JavaScript/
TypeScript, Python, Ruby, Rust, and Swift. It does not cover Lua, PHP, or Zig.
Stock query coverage differs by language and query suite.

CodeQL's licensing/availability must be checked for the repository being
analyzed. GitHub documents availability for public repositories and for
eligible organization-owned private repositories with GitHub Code Security;
do not silently make a commercial-only dependency mandatory for every Lineage
user.

Create one database per language. Compiled projects may require the project's
real build command; consult CodeQL's build-mode documentation rather than
assuming `autobuild` saw every source file.

```sh
mkdir -p tmp/codeql tmp/lineage-sarif

codeql database create tmp/codeql/ruby \
  --language=ruby \
  --source-root=.

codeql database analyze tmp/codeql/ruby \
  --format=sarifv2.1.0 \
  --sarif-category=ruby \
  --output=tmp/lineage-sarif/codeql-ruby.sarif
```

The CodeQL CLI groups some source languages under one extractor. Use `cpp` for
C/C++, `java` for Java/Kotlin, and `javascript` for JavaScript/TypeScript; the
other relevant CLI identifiers are `csharp`, `go`, `python`, `ruby`, `rust`,
and `swift`. Keep separate SARIF categories/source buckets when a repository
contains multiple analyzed language groups.

For a compiled language, use a build mode appropriate to the repository. A
representative manual-build shape is:

```sh
codeql database create tmp/codeql/cpp \
  --language=cpp \
  --source-root=. \
  --command='cmake --build build'

codeql database analyze tmp/codeql/cpp \
  --format=sarifv2.1.0 \
  --sarif-category=cpp \
  --output=tmp/lineage-sarif/codeql-cpp.sarif
```

Pin the CodeQL CLI/query-pack version in CI. Do not use absence of a CodeQL
result as proof that an alias is unique, a lifetime is safe, or two accesses
cannot race.

Official references:

- [CodeQL compiled language and build-mode support](https://docs.github.com/en/code-security/concepts/code-scanning/codeql/codeql-for-compiled-languages)
- [CodeQL query packs](https://docs.github.com/en/code-security/concepts/code-scanning/codeql/query-packs)
- [CodeQL `database analyze` SARIF output](https://docs.github.com/en/enterprise-cloud@latest/code-security/reference/code-scanning/codeql/codeql-cli-manual/database-analyze)
- [GitHub SARIF/code-scanning availability and contract](https://docs.github.com/en/code-security/reference/code-scanning/sarif-files/sarif-support)

## Language Matrix

| FactMine language | Preferred semantic baseline | Useful supplement | Direct SARIF path | Assessment |
| --- | --- | --- | --- | --- |
| Ruby | CodeQL | Brakeman for Rails | Both emit SARIF | Strong external baseline; FactMine remains necessary for Ruby-to-CLEAR ownership facts |
| Python | CodeQL | Ruff for lint/correctness | Both emit SARIF | Strong general baseline; proposed iterator rule needs Python-specific semantics |
| JavaScript | CodeQL | ESLint ecosystem | CodeQL direct; GitHub documents an ESLint SARIF formatter | Strong general baseline; mutation during iteration is usually logical, not memory invalidation |
| TypeScript | CodeQL | TypeScript/ESLint diagnostics | CodeQL direct; formatter/converter for other diagnostics | Strong general baseline with type/build configuration caveats |
| Java | CodeQL | Error Prone and Infer RacerD | CodeQL direct; adapt non-SARIF outputs if needed | Strong iterator and concurrency ecosystem; compare before building |
| Kotlin | CodeQL Java/Kotlin | Detekt/compiler diagnostics | CodeQL direct; converter may be needed | Good baseline only when the Kotlin build is captured |
| Swift | CodeQL | compiler/static-analyzer diagnostics | CodeQL direct | Good baseline with build capture required |
| Go | CodeQL | gosec and Go race detector | CodeQL/gosec direct; race output needs an evidence adapter | Strong static plus runtime combination |
| Rust | CodeQL and compiler | Clippy, Miri, Loom | CodeQL direct; JSON/SARIF adapters for other tools | Safe Rust already prevents major alias/data-race classes; unsafe/runtime evidence remains important |
| C | CodeQL | Clang/Infer and sanitizers | CodeQL direct; compiler/analyzer SARIF or adapters | Mature ecosystem; do not rebuild UAF/race parity in FactMine by default |
| C++ | CodeQL | Clang/Infer and sanitizers | CodeQL direct; compiler/analyzer SARIF or adapters | Mature but semantics are complex; library/container models dominate |
| C# | CodeQL | Roslyn/.NET analyzers | `ErrorLog` can emit SARIF 2.1 | Strong external baseline |
| PHP | Psalm | PHPStan as additional type evidence | Psalm emits SARIF; PHPStan needs a formatter/converter | Use Psalm before new FactMine defect detectors |
| Lua | no comparable semantic baseline identified | Luacheck/compiler-specific tools | converter required | Explicit gap; imported lint is not alias-hazard parity |
| Zig | no comparable semantic baseline identified | compiler, SlopCop, Miri/Loom-style project evidence where available | converter/first-party SARIF | Explicit gap; retain FactMine/SlopCop experiments without claiming mature parity |

## Direct SARIF Examples

These commands generate useful ecosystem evidence. They do not all detect the
alias hazards in the design document.

### Ruby/Rails: Brakeman

```sh
brakeman -f sarif -o tmp/lineage-sarif/brakeman.sarif
```

[Brakeman SARIF support](https://brakemanscanner.org/blog/2020/09/28/brakeman-4-dot-10-dot-0-released)

### Python: Ruff

```sh
ruff check . --output-format sarif \
  > tmp/lineage-sarif/ruff-python.sarif
```

[Ruff output formats](https://docs.astral.sh/ruff/configuration/)

### JavaScript/TypeScript: ESLint

GitHub's SARIF integration guide uses the Microsoft ESLint SARIF formatter:

```sh
eslint . \
  -f node_modules/@microsoft/eslint-formatter-sarif/sarif.js \
  -o tmp/lineage-sarif/eslint.sarif
```

[GitHub third-party SARIF example](https://docs.github.com/en/code-security/how-tos/find-and-fix-code-vulnerabilities/integrate-with-existing-tools/upload-sarif-file)

### Go: gosec

```sh
gosec -no-fail -fmt sarif \
  -out tmp/lineage-sarif/gosec.sarif ./...
```

[gosec SARIF usage](https://github.com/securego/gosec)

### C#: compiler and Roslyn analyzers

Add an MSBuild property or pass its equivalent on the command line:

```xml
<PropertyGroup>
  <ErrorLog>tmp/lineage-sarif/dotnet.sarif,version=2.1</ErrorLog>
</PropertyGroup>
```

[C# `ErrorLog` SARIF output](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/compiler-options/errors-warnings#errorlog)

### PHP: Psalm

Use Psalm's SARIF output for its static/security analysis, then import the
artifact through the common Lineage command above. Pin the Psalm version and
record the exact invocation in the analyzed repository because Psalm
configuration and security/taint modes materially change coverage.

[Psalm SARIF/security-analysis documentation](https://psalm.dev/docs/security_analysis/)

## Runtime and Specialized Evidence

SARIF findings and dynamic evidence answer different questions. Continue to
run the relevant verifier and feed its coverage/evidence into SlopCop/Lineage:

- Go race detector for observed Go races;
- TSan for observed C/C++ thread races;
- ASan/LSan/UBSan for native lifetime and undefined behavior;
- Loom for modeled Rust/Zig concurrency where the project supports it; and
- Miri for Rust undefined behavior and unsafe execution.

Do not turn console output into a low-information SARIF warning if Lineage or
SlopCop already has a structured evidence ingestion path. A converter should
preserve stacks, conflicting accesses, threads/tasks, and tool version.

## Required Validation Before Enabling a Source

For each tool/language/repository combination:

1. pin the analyzer and rule-pack version;
2. record the exact build and analysis command;
3. verify the analyzer included the intended source files/generated code;
4. require repository-relative, case-correct paths and matching commit SHA;
5. import under a stable source bucket unique to tool and language;
6. review skipped files/results reported by Lineage;
7. prove one positive and one clean negative fixture lands on the expected
   logical unit;
8. preserve rule IDs, severity, fingerprints, code-flow paths, and properties;
   and
9. measure overlap with first-party Decomplex/SlopCop findings before adding a
   duplicate detector.

## When to Build a FactMine/Decomplex Detector

Build only when at least one condition holds:

- Ruby-to-CLEAR needs the underlying semantic fact for compiler correctness;
- no mature analyzer covers the language/hazard;
- alias-aware analysis demonstrably catches indirect cases the baseline misses;
- the repository can produce novel cross-product evidence, such as joining an
  exact alias path with Lineage history and SlopCop verification; or
- licensing/deployment constraints make the external baseline unusable for the
  intended users.

Even then, compare against imported findings on a labeled corpus. “Runs on all
FactMine languages” is not a quality gate; measured precision, declared
semantic coverage, and useful net-new findings are.
