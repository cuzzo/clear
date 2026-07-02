# Auto-Format Issues

## Lexer Migration

- Fixed during this migration: `clear fmt` previously formatted uppercase symbol literals with a space after the colon, for example `:ELLIPSIS` became `: ELLIPSIS`.
- `clear fmt` wraps long receiver chains in `IF`/`ELSE_IF` predicates by splitting `.s.scan(...)` across lines, then indents the following `ELSE_IF` chain as if it were nested. The generated lexer remains parseable, but the visual structure is misleading and review-hostile.
- `clear fmt` leaves long `unsupportedRuby(...)` placeholders and unsupported Ruby comment blocks over 120 columns. That is partly a ruby-to-clear placeholder problem, but formatter output does not produce a reviewable migration artifact from those placeholders.

## Parser Migration

- Fixed during this migration: `clear autofix` could rewrite an undefined uppercase constructor/type name such as `Lexer` to a lowercase in-scope variable such as `exp` under the "closest in-scope variable" typo fix. Uppercase identifiers no longer receive that unsafe automatic variable replacement.
- `clear fmt` successfully parses the generated parser and parser tests, but leaves many long generated signatures, conditions, assertions, and helper calls over 120 columns. The formatter reports warnings without wrapping them into reviewable shapes.
