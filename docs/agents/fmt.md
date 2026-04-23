# `clear fmt` — formatter rules

This is the canonical rule set for the CLEAR formatter. Implementation lives
in `src/backends/formatter.rb` and is wired into the `./clear fmt` CLI.

The formatter is **deterministic** and **idempotent**: `fmt(fmt(x)) == fmt(x)`.
On parse error it refuses to write and exits non-zero. On ambiguous
comment attachment it errors with enough context for the user to resolve.

---

## 1. Indent

- **2 spaces** per level. Never tabs.
- Block body is +1 from the block's keyword line.
- `CATCH`, `DEFAULT`, `ELSE`, `ELSE_IF` sit at the enclosing keyword's column
  (`FN` / `IF` / `WITH`), **not** at body indent.
- `TYPE` / `STRUCT` / `UNION` / `ENUM` body at +1.
- General expression continuation-indent rules are **deferred** (context-aware;
  to be specified after v0 ships).

## 2. Line length

- Soft limit: **120 chars**. Exceeding the limit emits a warning; the
  formatter does **not** forcibly wrap except in the specific cases below.
- `CATCH` multi-item lists (e.g. `CATCH A, B, C`) and `WITH(...)` filters:
  warn only, never forced.

## 3. Forced wraps

### 3.1 FN signature exceeds 120

```clear
FN foo(
  p1: T,
  p2: T
)
RETURNS T ->
  body
END
```

- `(` stays on the `FN` line.
- Each parameter on its own line at +1.
- `)` and `RETURNS T ->` return to the `FN` column (no indent).
- `RETURNS ... ->` is always present (compiler requires it).
- Body at +1.

### 3.2 WITH with 2+ captures — always wrap

And also wrap when there is exactly 1 capture and the line exceeds 120.

```clear
WITH
  EXCLUSIVE x AS y,
  EXCLUSIVE z AS a {
    body
  }
```

- Captures at +1.
- Body at +2.
- Closing `}` at +1.

### 3.3 WITH with ON clause — always wrap

Any `ON TIMEOUT` / `RETRY(N) THEN ...` / `POSSIBLE_DEADLOCK` on a WITH forces
this shape, regardless of length:

```clear
WITH EXCLUSIVE x AS y {
    body
  }
  ON TIMEOUT(...) RAISE
```

- Body at +2, closing `}` at +1, `ON ...` at +1.

### 3.4 Pipeline with 2+ `s>` stages

Each stage on its own line.

```clear
users
  s> parseHeader
  s> parseBody
  s> fetchUser
  s> renderHomePage
```

Special case — `s> RECOVER(...)` receives **one extra indent level** relative
to its sibling `s>` stages:

```clear
users
  s> parseHeader
  s> parseBody
  s> fetchUser
    s> RECOVER(defaultUser())
  s> renderHomePage
```

### 3.5 Method chains

`.a().b().c()` with **more than 3** calls, OR a total length exceeding
**80 chars**, forces one call per line:

```clear
result
  .a()
  .b()
  .c()
  .d()
```

### 3.6 Pipeline / chain assignment

When `x = users s> ...` (or `x = obj.a().b()...`) has a first line exceeding
**80 chars**, drop the RHS to the next line:

```clear
x =
  users
    s> a
    s> b
```

- Receiver at +1 from the statement column.
- Chain / stages at +2 from the statement column.

### 3.7 Block pipeline stage `s> { ... }`

- Single statement that fits 120: inline on the same line as `s>`.
  ```clear
  s> { doOneThing(x) }
  ```
- Multi-statement or >120 chars: open `{` at the end of the `s>` line, body
  at +2 from the pipeline, closing `}` at +1.

### 3.8 STRUCT / UNION / ENUM

**Always** one item per line, regardless of length.

```clear
STRUCT Point {
  x: Int64,
  y: Int64
}
```

### 3.9 Long call arguments

When **any** argument to a function call is itself multi-line (BG/DO block
with 2+ stmts, wrapped STRUCT literal, wrapped chain, wrapped pipeline) OR
the full call exceeds 120 chars, wrap **all** arguments onto their own
lines:

```clear
foo(
  x(y(z(blah))),
  STRUCT{a: b, c: d},
  BG { foo() }
)
```

All-or-nothing — if one argument triggers wrap, every argument wraps, for
consistency with the FN-signature rule. `)` returns to the call column.

### 3.10 BG / DO blocks

- 0 or 1 statements: inline — `BG { stmt }` — if it fits 120.
- 2 or more statements: **always** multi-line.
- Capability form `BG { @micro -> stmt }`: prefer one line; if the
  statement overflows, wrap body with the statement at +2:

  ```clear
  BG {
    @micro ->
      reallyLongExpressionThatOverflows(args)
  }
  ```

### 3.11 CONCURRENT chains

When `CONCURRENT(...)` takes 2+ parameters, the following pipeline stage
(`EACH` / `WHERE` / etc.) drops to the next line at the `CONCURRENT`
column:

```clear
items
  s> CONCURRENT(pool_size: 8, key: _.id)
     EACH { _.doWork() }
```

### 3.12 Non-rules (explicitly not automated)

- **Nested unary-call -> pipeline rewrite**: `f1(f2(f3(x)))` does NOT
  become `x s> f3 s> f2 s> f1`. That is a semantic rewrite — it rotates
  which function is "outermost", does not work for multi-arg calls, and
  belongs in `clear lint`, not `clear fmt`.

## 4. Spacing

- One space around binary operators, `=`, and after `,` and `;`.
- No space inside `()`, `[]`, `{}` (single-line forms).
- No space between tense sigils and the type: `!T`, `?T`, `%T`, `~T`, `~?T[]`.
- Capability attachment:
  - **Type position** (struct fields, function params, return types): flush —
    `T@locked`.
  - **Value position** (literals, call sites, return values): spaced —
    `1 @locked`, `foo() @locked`.

## 5. Comments

- Trailing (inline) comment: **2 spaces** before the `--`, then **1 space**
  after: `code  -- note`.
- Leading single-line comment: indent **matches the code line immediately
  below** it.
- Comment that is the **last line in a block**: indent matches the previous
  line.
- Ambiguous attachment (e.g. orphan comment between blocks with no clear
  anchor) -> formatter errors with file/line context; user resolves.

## 6. Blank lines

- Exactly **1 blank line** before each `CATCH` / `DEFAULT` clause.
- 3 or more consecutive blank lines -> **collapsed to 2**.
- 2 blank lines are permitted inside function bodies (e.g., to separate
  logical sections).
- Trailing blank lines stripped; file ends with exactly one newline.

## 7. One-liners

- **Allowed**: `IF c -> stmt;`, `WHILE c -> stmt;` (the arrow form).
- **Forbidden (must be multi-line)**:
  - Any form using `THEN` or `DO ... END`.
  - `FN` — always multi-line, always ends with `END` on its own line.

## 8. Other canonicalizations

- **No trailing commas** in wrapped lists. (Currently a parse error.)
- **No alignment** of adjacent `=`, `:`, arrows, comments. Spacing rules win.
- **Long strings** are not wrapped.
- **Long integer `_` separators** are normalized once the parser supports
  them; until then, preserved as-is.
- **Keyword casing** is enforced by the compiler; the formatter ignores it.

## 9. Error modes

- **Parse error** -> refuse to write, print error with file:line:col, exit
  non-zero.
- **Ambiguous comment attachment** -> refuse to write, print the comment's
  file:line and surrounding context, exit non-zero.

## 10. Idempotence

`fmt(fmt(x)) == fmt(x)` is a hard invariant. Every rule above must be
deterministic given valid input. Any rule that can't be made idempotent is
a bug in the rule, not in the code.

---

## Implementation status

**v2 (current):**
- Long call / struct-literal argument wrap (§3.9): any interior NL OR
  projected line length (including receiver) exceeding 120 → all args
  on their own lines at +1; `)` or `}` back at the call column.
  Applies to calls `name(...)`, `obj.method(...)`, filter forms like
  `WITH(...)`, and struct literals `Type{...}`. Processed bottom-up
  via recursive descent so an inner wrap triggers an outer wrap.
- Capability attach position (§4): `@X` flush-attaches to a type token
  (`TYPE_ID`, `]`) when the position is a type context (after `:`,
  `RETURNS`, or inside a type annotation scope). Value-position
  `1 @locked`, `foo() @locked` keeps the space.
- 120-char width warnings (§2): after formatting, lines exceeding 120
  chars emit `path:line: warning: line length N exceeds 120` to stderr.
  Opt out with `clear fmt --no-warn`.
- Digit-group separators (§8): decimal ints and floats get canonical
  `_` separators when either side of the decimal has more than 4
  digits. Integer side groups from the right (`1_234_567`); fractional
  side groups from the left (`0.123_456`). Numbers at or below 4 digits
  are canonicalized WITHOUT separators (`1_234` → `1234`). Type suffixes
  (`_i32`, `_f64`, ...) preserved. Hex/oct/bin literals are left
  untouched — grouping conventions vary (4, 3, 8) and user choice wins.
  Requires matching lexer support: a closed suffix set (i8..f64) so
  `0xDEAD_BEEF` is unambiguously hex-with-separator, not hex-with-suffix.

**v1.2 (forced wraps):**
- WITH forced wraps (§3.2, §3.3): 2+ captures always wrap; trailing
  ON/RETRY/POSSIBLE_* clause forces the body-at-+2, `}`-at-+1,
  ON-at-+1 shape. Both triggers compose.
- Pipeline forced wraps (§3.4, §3.7): 2+ `s>` stages → each stage on
  its own line at +1 from receiver; `s> RECOVER(...)` receives one
  extra indent level (+2) relative to sibling stages.
- FN signature wrap (§3.1): projected single-line length > 120 OR
  source already wrapped between `(` and `)` → each param at +1,
  `)` and `RETURNS T ->` back at FN column.
- BG/DO multi-statement wrap (§3.10): 0–1 statements stay inline,
  2+ statements force multi-line (each statement on its own line).
- STRUCT/UNION/ENUM one-per-line (§3.8) — from v1.1.

Introduced `:INDENT_OPEN` / `:INDENT_CLOSE` phantom tokens that the
renderer uses to adjust depth in positions where no `{`/`END`/`->`
drives the change. Placement before any code on a line acts
pre-render; placement after code acts post-render.

**v1.2 deferred (v2 candidates):**
- Long call argument wrap (§3.9) — needs whole-call multi-line
  detection plus all-or-nothing wrap.
- Pipeline / chain assignment drop when first line >80 (§3.6).
- CONCURRENT multi-arg stage drop (§3.11) — depends on exact column
  alignment with the `CONCURRENT` keyword position, which the
  depth-based renderer can't express directly.

**v1.1:**
- Parse validation (§9).
- Lossless tokenization (preserves strings incl. `${}`, comments, numerics).
- Intra-line spacing canonicalization (§4) — operators, commas,
  semicolons, sigil attach, call/index attach, `:` type annotations,
  unary operators at expression-start positions, `WITH(...)` attach.
- Canonical comment spacing (§5): 2 spaces before trailing `--`, 1 after.
- FN one-liner expansion (§7): every FN becomes multi-line; `;`
  statement boundaries in the body are split onto lines; `ELSE` /
  `ELSE_IF` / `CATCH` / `DEFAULT` move to their own line.
- IF / WHILE / FOR one-liner expansion (§7): one-line `THEN` / `DO ... END`
  forms are expanded to multi-line. Multi-line forms preserved as-is.
- STRUCT / UNION / ENUM (§3.8): one field/variant per line; internal
  NLs and comments preserved (so UNION bodies with default-method FN
  declarations plus leading comments round-trip correctly).
- Indent recomputation (§1 base): 2-space, from block structure.
- Blank-line normalization (§6): collapse 3+ to 2, 1 before
  CATCH/DEFAULT, strip trailing.
- CATCH / DEFAULT / ELSE / ELSE_IF outdent (§1).
- Idempotent: verified `fmt(fmt(x)) == fmt(x)` on the full
  transpile-tests corpus (306 files, 0 parse errors, 0 drift).

**v1.2 (next — forced wraps):**
- FN signature forced wrap when >120 chars (§3.1).
- WITH forced wraps: 2+ captures always, 1-cap >120, ON clause shape
  (§3.2, §3.3).
- Pipeline forced wraps incl. `s> RECOVER` extra indent (§3.4, §3.7).
- Method chain forced wrap (§3.5).
- Pipeline/chain assignment drop when first line >80 chars (§3.6).
- Long call argument wrap — all-or-nothing (§3.9).
- BG / DO multi-statement wrap + capability-form rules (§3.10).
- CONCURRENT multi-arg stage drop (§3.11).

**v2 (later):**
- Warn-only 120-char width reports (§2).
- Continuation indent for arbitrary expression wrap (§1 general rule).
- Ambiguous comment attachment detection (§9).
- Integer `_` separator normalization (§8, needs parser support).
- Canonical capability attach rules (§4, type vs value position).
