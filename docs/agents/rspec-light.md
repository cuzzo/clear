# Test framework — first stdlib package

CLEAR already ships a parser-level test grammar — `TEST` / `WHEN` /
`TEST THAT` / `ASSERT` / `ASSERT_RAISES` / `BENCHMARK` / `STUB`,
implemented in `src/ast/parser.rb#parse_test_block` and friends.
This document specs the **first stdlib package** — `stdlib/test/` —
that fills in everything the existing grammar already implies but
doesn't yet provide: lazy fixtures, hooks, selection, and a
predicate library so plain `ASSERT pred` reads like English.

The goal is **not** to clone RSpec. The fluent matcher chain
(`expect(x).to(matcher)`) reads as a foreign language to anyone who
hasn't done significant Ruby work, and it requires every reader to
internalize matcher composition rules to parse a test. CLEAR's
existing test grammar already walks a different and better line:

- **Keywords for structure** (`TEST` / `WHEN` / `TEST THAT`) — the
  shape of a test file is parser-visible, not buried in nested
  method calls.
- **Natural English for description** (`WHEN "addition"`,
  `TEST THAT "adds positives"`).
- **Direct predicates for assertions** (`ASSERT expr == val, "msg"`) —
  no chain to memorize, no matcher namespace to learn.
- **Declarative top-down stubs** (`STUB query RETURNS "mock"`).

Every addition below preserves that grain.

---

## 1. Reference frameworks (what to take, what to leave)

| Framework | Take | Leave |
|---|---|---|
| **RSpec** | The idea that test files have *shape* (group → context → spec). Random ordering. Focus/skip. Hooks. | The fluent matcher chain. The implicit-subject magic. `let`/`subject` magic. |
| **ExUnit** | Per-spec process isolation (CLEAR analogue: per-spec fiber). Setup-as-context-map. | Macro-heavy assertion library. |
| **Crystal Spec** | Native-compiled DSL that's RSpec-shaped but predictable. | Deep RSpec-vocabulary inheritance. |
| **Go `testing`** | Subtests, table-driven tests as first-class. Tests are just functions. | Lack of grouping for non-trivial suites. |
| **Zig `std.testing`** | Lightweight, no DSL — `test "name" { ... }`. **Already our compile target.** | Insufficient grouping for non-trivial suites. |
| **Ruby + ActiveSupport** | Predicate-method idiom (`x.nil?`, `x.present?`, `x.blank?`, `n.between?(a, b)`). | The Rails-specific bits. |

The shape sits between Crystal/RSpec (rich grouping, hooks, fixtures)
and Go/Zig (no fluent matchers; assertions are direct predicates).
The existing CLEAR grammar already hit that mark; this document fills
in the gaps.

---

## 2. What's already shipped

```clear
TEST Calculator DO
  WHEN "addition" DO
    TEST THAT "adds two positives" DO
      ASSERT add(1, 2) == 3;
    END

    TEST THAT "adds two negatives" DO
      ASSERT add(-1, -2) == -3, "negatives still add";
    END
  END

  WHEN "stubbed dependency" DO
    STUB query RETURNS "mock";

    TEST THAT "uses the stub" DO
      x = Client{ host: "localhost" };
      ASSERT x.query("any") == "mock";
    END
  END
END
```

Parser, annotator, MIR lowering, and Zig-test lowering all in place.
Every addition below either ships in pure CLEAR as `stdlib/test/`
(no language work) or adds a small, specific keyword extension that
fills an obvious gap.

---

## 3. v1 — what ships first

### 3.1 No new ASSERT vocabulary; ship a predicate library

CLEAR's existing `ASSERT pred` and `ASSERT a == b` cover boolean and
equality predicates. Everything else is better served by
**ActiveSupport-style UFCS predicates** — methods on values that
read as English when fed to `ASSERT`:

```clear
ASSERT user.nil?;
ASSERT users.present?;
ASSERT cart.empty?;
ASSERT count.zero?;
ASSERT score.between?(0, 100);
ASSERT temp.close_to?(98.6, 0.1);
ASSERT name.starts_with?("dr.");
ASSERT email.matches?("^.+@.+$");
ASSERT scores.all?(%(s) -> s > 0);
ASSERT items.contains?(target);
```

These predicates are useful well outside testing — in app code, in
pipelines, anywhere a boolean read should sound like English.

**Predicate set to ship in stdlib** (each is a small UFCS FN):

| On `?T` (optional) | `.nil?`, `.present?` |
| On collections / strings | `.empty?`, `.present?`, `.blank?`, `.contains?(x)`, `.any?`, `.all?(%pred)` |
| On numbers | `.zero?`, `.positive?`, `.negative?`, `.between?(low, high)`, `.close_to?(val, tol)` |
| On strings | `.starts_with?(s)`, `.ends_with?(s)`, `.matches?(regex)` |

**The one truly structural case** — change-by — does **not** need a
keyword. Three lines is fine:
```clear
before = userCount();
register("bob");
ASSERT (userCount() - before) == 1, "user count increased";
```

**Net change to ASSERT grammar: zero.** The work is purely stdlib.

### 3.2 Lazy fixtures — `LET` (needs core support)

```clear
TEST Counter DO
  LET counter = Counter{ value: 0 } @shared:locked;

  TEST THAT "starts at zero" DO
    ASSERT counter.value == 0;
  END

  TEST THAT "increments on bump" DO
    counter.bump();
    ASSERT counter.value == 1;
  END

  WHEN "with seeded value" DO
    LET counter = Counter{ value: 100 } @shared:locked;       # shadow

    TEST THAT "starts at 100 here" DO
      ASSERT counter.value == 100;
    END
  END
END
```

**Semantics:**
- `LET name = expr;` binds `name` in the lexical scope of every
  `TEST THAT` below it, including in nested `WHEN` blocks.
- The RHS is evaluated **lazily** — only on first reference within
  a given test, not at registration time.
- The cached value resets between tests. Each `TEST THAT` sees a
  fresh `counter`.
- `WHEN`-level `LET` shadows enclosing `TEST`-level `LET`.

**Why a keyword instead of a `Lazy<T>` stdlib type:** the stdlib
form is `counter = Lazy.new(USE -> Counter{...})` and every reference
is `counter.get().value`. Verbose at every read site. A keyword keeps
reference sites clean.

**Implementation footprint:**
- Parser: new statement form valid inside `TEST` / `WHEN` blocks
  (~50 lines).
- Annotator: scope rule that injects `name` into every descendant
  `TEST THAT`'s scope, with type inferred from `expr` (~50 lines).
- Lowering to Zig: lower each `TEST THAT` body to a Zig `test "..."`
  block; emit each `LET` as a lazy-init `var` inside that block
  (`var __counter_init: bool = false;` plus `var __counter: T = ...;`
  and a getter macro). Memoization is per Zig test, which already
  matches the per-spec semantics we want (~30 lines).
- Runner: nothing new — Zig's runner handles per-test isolation.

### 3.3 Hooks — `BEFORE EACH` / `AFTER EACH` / `BEFORE ALL` / `AFTER ALL`

```clear
TEST FileWriter DO
  LET tempPath = mkTempFile("test");

  AFTER EACH DO
    unlink(tempPath);
  END

  TEST THAT "writes content" DO
    writeFile(tempPath, "hello");
    ASSERT readFile(tempPath) == "hello";
  END
END

TEST DatabaseSuite DO
  BEFORE ALL DO
    db.migrate();
  END

  AFTER ALL DO
    db.drop();
  END

  TEST THAT "inserts a row" DO
    db.insert("users", "alice");
    ASSERT db.count("users") == 1;
  END
END
```

**Why both `EACH` and `ALL`, both explicit:** RSpec's defaults are
implicit (`before(:each)` is the default `before(...)`) which is a
constant source of bugs. CLEAR's style is *explicit and verbose over
magic and terse* — the keyword is always `EACH` or `ALL`, never just
`BEFORE`.

**Run order** (outer-to-inner, then reverse for AFTER):

```
TEST::BEFORE ALL
  TEST::BEFORE EACH
    WHEN::BEFORE EACH
      TEST THAT body
    WHEN::AFTER EACH
  TEST::AFTER EACH
TEST::AFTER ALL
```

`AFTER EACH` and `AFTER ALL` run even on assertion failure (modeled
as `defer` in lowering).

**Implementation footprint:**
- Parser: `BEFORE EACH DO ... END`, `AFTER EACH DO ... END`,
  `BEFORE ALL DO ... END`, `AFTER ALL DO ... END` recognized inside
  `TEST` / `WHEN` bodies (~40 lines).
- Annotator: stash hook bodies on the parent `TestBlock` /
  `WhenBlock` AST node.
- Zig-test lowering: `BEFORE EACH` body inlines at the top of each
  `TEST THAT` Zig block; `AFTER EACH` lowers to `defer` at the same
  position. `BEFORE ALL` / `AFTER ALL` lower to a Zig
  `test "__before_all_<group>"` and `__after_all_<group>` that the
  runner sequences via test-name ordering (or, longer-term, via a
  custom Zig test runner).

### 3.4 Selection — `FOCUS` and `TAGS`

```clear
TEST Auth DO
  FOCUS TEST THAT "the failing one I'm debugging right now" DO
    ASSERT login("alice", "pw").present?;
  END

  TEST THAT "slow integration thing" TAGS [slow, integration] DO
    ASSERT db.connect().healthy?;
  END

  TEST THAT "fast unit thing" TAGS [unit] DO
    ASSERT hash("pw") != "pw";
  END
END
```

CLI:
```
clear test --focus auth_test.clear        # only FOCUS-marked specs
clear test --tag slow                   # only specs tagged slow
clear test --tag slow --tag integration # union of tags
clear test --skip-tag slow              # exclude tagged slow
clear test --seed 42                    # deterministic random order
clear test --fail-fast                  # stop on first failure
```

**Lowering strategy** — use Zig's existing `--test-filter`:

The CLEAR-to-Zig lowering encodes tags into the Zig test name:
```
TEST THAT "slow integration thing" TAGS [slow, integration]
```
becomes
```zig
test "Auth :: slow integration thing #slow #integration" { ... }
```

`clear test --tag slow` translates to `zig test --test-filter "#slow"`.
No custom runner needed; Zig's filter does the work.

`FOCUS` lowers to a `#focus` suffix. `clear test --focus` translates
to `zig test --test-filter "#focus"`.

**Implementation footprint:**
- Parser: `FOCUS` as optional prefix on `TEST THAT`, `TAGS [<id>, ...]`
  as optional suffix (~40 lines).
- Annotator: pass through to the `TestThat` AST node as metadata.
- Zig-test lowering: append tag suffixes to the Zig test name.
- CLI (Ruby side, for now): translate `--tag` / `--focus` to the
  appropriate `--test-filter` invocation (~30 lines).

### 3.5 Pending — `PENDING` keyword

```clear
TEST FuturePlans DO
  PENDING TEST THAT "supports trailing commas in struct literals" DO
    p = Point{ x: 1, y: 2, };       # trailing comma — not yet
    ASSERT p.x == 1;
  END
END
```

Lowers to a Zig test body that immediately returns
`error.SkipZigTest`. Zig's runner counts that as "skipped" rather
than pass or fail, which is exactly the semantics we want for v1.

**Implementation footprint:**
- Parser: `PENDING` as optional prefix on `TEST THAT` (~10 lines).
- Lowering: emit `return error.SkipZigTest;` as the body's first
  statement.

### 3.6 Equality diff rendering

Today: `ASSERT counter == expected` failure prints "assertion failed"
plus a Zig stack trace.

After this lands:
```
TEST Counter / increments on bump (failed)
  expected counter == Counter{ value: 1, generation: 0 }
  actual                  Counter{ value: 2, generation: 0 }
                                 ^---^
  at counter_test.clear:14
```

**Implementation:** `ASSERT a == b` lowers to emit a CLEAR-side
`printDiff(a, b)` call before the `try expectEqual(a, b)`. The diff
renderer walks struct fields one level deep, showing `=`/`≠` per
field with primitives shown inline.

Pure stdlib, ~200 lines. Biggest single UX win for v1.

### 3.7 Output formatting — defer to Zig's runner for v1

Zig's test runner already prints pass/fail counts, per-test status
with `--summary all`, and stack traces on failure. That covers the
basic case.

Tree-format and JSON formatters require either a custom Zig test
runner (`test_runner = ...` in `build.zig`) or post-processing Zig's
output. **Both deferred to v2.** v1 ships with Zig's default output
plus the equality diff rendering above.

This trims the v1 package by ~300 lines and makes the whole thing
2–3 weeks of work instead of 6+. The right ROI signal for custom
formatters is concrete CI / IDE pressure, which we don't have yet.

### 3.8 Parallel execution — defer to Zig's runner for v1

Zig 0.14+ has experimental parallel test execution. CLEAR's
fiber-per-spec story (using `CONCURRENT(workers: N) EACH`) requires
a custom Zig test runner to wire in cleanly. **Defer to v2** when
the runtime's thread-pool story stabilizes and there's a concrete
need.

For v1, tests run sequentially through Zig's default runner. Per-spec
isolation is preserved because each `TEST THAT` is its own Zig
`test "..."` block — Zig already gives us that.

### 3.9 Summary — what's parser, what's stdlib, what's deferred

| Feature | v1 ships? | Where |
|---|---|---|
| `TEST` / `WHEN` / `TEST THAT` / `ASSERT` / `ASSERT_RAISES` / `STUB` / `BENCHMARK` | ✓ already shipped | parser |
| Predicate library (`.nil?`, `.present?`, `.empty?`, `.between?`, ...) | ⚙ v1 | pure stdlib |
| Equality diff rendering | ⚙ v1 | pure stdlib + Zig-test lowering |
| `LET name = expr;` | ⚠ v1 | parser + annotator + Zig-test lowering |
| `BEFORE EACH` / `AFTER EACH` / `BEFORE ALL` / `AFTER ALL` | ⚠ v1 | parser + Zig-test lowering |
| `FOCUS` / `TAGS [...]` | ⚠ v1 | parser + Zig-test name suffix + CLI flag translation |
| `PENDING` | ⚠ v1 | parser + Zig-test lowering |
| Tree / JSON output formatters | ✗ v2 | custom Zig test runner |
| Fiber-per-spec parallel runner | ✗ v2 | custom Zig test runner + runtime |
| Snapshot testing, watch mode, mocks-beyond-STUB, shared-examples-across-files | ✗ v2+ | various |

**Total parser / annotator work for v1: ~190 lines.** Bulk is `LET`
(~100) and hooks (~40); the rest are ~10–40-line additions. No
big-bang grammar change.

**Total stdlib package: ~600–800 lines** — predicate library, diff
renderer, CLI flag translation. The framework "is" the existing
test grammar plus a Zig-runner-aware lowering; the stdlib package
is the predicate vocabulary and the diff-on-failure printer.

---

## 4. v2+ deferred (explicit list)

- **Custom Zig test runner** — unlocks tree/JSON formatters, native
  parallel execution, "skipped" being a first-class state separate
  from `error.SkipZigTest`.
- **Snapshot testing** — write expected output to a file, diff on
  re-run; needs a snapshot file format + diff renderer + an update
  flag.
- **Watch mode** (`clear test --watch`) — needs filesystem-watch
  bindings (inotify/fsevents).
- **Coverage integration** — needs CLEAR-side coverage
  instrumentation; out of scope until v0.3.
- **Property-based tests** — defer to the v0.2 LOOM/VOPR framework.
- **Mocks beyond `STUB`** — partial mocks, expectation ordering,
  call-arg matching. `STUB` covers 80% of real needs.
- **Shared test groups across files** — `INCLUDE Name` style;
  needs a small parser extension and hygiene rules.
- **Recursive struct diff rendering** — v1 ships one-level-deep
  diff for primitives, lists, and structs; full recursive renderer
  lands later.

---

## 5. File layout

```
stdlib/
  test/
    src/
      lib.clear              # public re-exports
      predicates.clear       # .nil? .present? .empty? .between? ...
      diff.clear             # equality-failure rendering
      cli.clear              # --tag / --focus translation to Zig --test-filter
    spec/
      predicates_spec.clear  # the test framework, tested in itself
      hooks_spec.clear
      let_spec.clear
      diff_spec.clear
```

The `spec/` directory inside the package is the **dogfood test
suite** — the framework testing itself in itself. If those tests
pass, the framework works. If they don't compile, the framework's
API or the language has a hole.

---

## 6. Open questions

1. **`STUB` and `LET` resetting.** Both reset per-spec. The Zig-test
   lowering already isolates state per Zig `test "..."` block, so
   reset is automatic — but the two features should share lowering
   helpers rather than each carrying their own. Worth a small
   refactor of `STUB` lowering when `LET` lands.

2. **Test discovery.** `clear test path/` already walks `*.clear`.
   Do we want a `_spec.clear` suffix convention so framework-style
   spec files vs application-level test files are visually
   distinguishable? Lean yes for stdlib's own tests
   (`predicates_spec.clear`); leave `_test.clear` available as the
   convention for application tests. Both runnable.

3. **Diff color.** Terminal color codes in failure output, with a
   `--no-color` flag and `NO_COLOR` env var fallback. Cheap,
   high-value. v1.

4. **`BEFORE ALL` ordering across multiple `TEST` blocks in one file.**
   When a file has `TEST A` and `TEST B`, do their `BEFORE ALL`s run
   in declaration order? Lean yes; document it. Worth pinning in a
   spec test to prevent drift.

5. **Predicate library naming consistency.** Ruby has both `empty?`
   (collection) and `blank?` (string-or-collection-or-nil). Do we
   ship both, or just `empty?`? Lean: ship both, with `blank?`
   defined as `nil? || empty?` for the union.

---

## 7. Implementation order

Each step lands as its own commit; review stays manageable, and at
every step the framework is incrementally more useful.

1. **`stdlib/test/` skeleton** — empty `lib.clear`, package resolver
   registration, smoke spec proving `REQUIRE "pkg:test"` works.
2. **Predicate library** — `.nil?`, `.present?`, `.empty?`, `.zero?`,
   `.positive?`, `.between?`, `.close_to?`, `.starts_with?`,
   `.ends_with?`, `.matches?`, `.contains?`, `.any?`, `.all?`,
   `.blank?`. Pure stdlib + a spec file.
3. **Equality diff rendering** — `printDiff(a, b)` walks one level
   deep on structs and prints `=`/`≠` per field. Lower `ASSERT a == b`
   to call it before the Zig `expectEqual`.
4. **Hooks** — `BEFORE EACH` / `AFTER EACH` / `BEFORE ALL` /
   `AFTER ALL` parser keywords + Zig-test lowering.
5. **`LET` keyword** — parser + annotator + lowering. Biggest single
   feature; ships standalone.
6. **`FOCUS` / `TAGS`** — parser + Zig test-name suffix + CLI flag
   translation.
7. **`PENDING`** — small.
8. **Dogfood port** — port a chunk of the existing Ruby `spec/`
   integration tests (the ones that test CLEAR programs end-to-end,
   not the ones that test the Ruby compiler) into pkg:test. Validates
   the framework against real workloads.

By step 5 (LET) the framework is genuinely usable for real test
authoring even if 6–8 ship later. Step 8 is the validation that
nothing critical was missed.
