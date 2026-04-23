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

**v0 (current):**
- Parse validation (§9).
- Indent recomputation from block structure (§1 base rule, excluding the
  §3 forced wraps).
- Blank-line normalization (§6).
- Trailing-whitespace stripping.
- Comments preserved in place (by line preservation).

**v1 (next):**
- Intra-line spacing canonicalization (§4).
- One-liner rules (§7).
- STRUCT / UNION / ENUM one-per-line (§3.8).
- FN signature forced wrap (§3.1).
- WITH forced wraps (§3.2, §3.3).
- Pipeline forced wraps, including `s> RECOVER` extra indent (§3.4, §3.7).
- Method chain forced wrap (§3.5).
- Pipeline / chain assignment drop (§3.6).
- CATCH outdent (§1 specific rule; handled at v0 block level but reverify).
- Canonical comment spacing (§5).

**v2 (later):**
- Width warnings (§2).
- Continuation indent (§1 general rule).
- Ambiguous comment detection (§9).
- Integer `_` separators (§8, needs parser).
