# Auto-Format Issues

## Lexer Migration

- Fixed during this migration: `clear fmt` previously formatted uppercase symbol literals with a space after the colon, for example `:ELLIPSIS` became `: ELLIPSIS`.
- `clear fmt` wraps long receiver chains in `IF`/`ELSE_IF` predicates by splitting `.s.scan(...)` across lines, then indents the following `ELSE_IF` chain as if it were nested. The generated lexer remains parseable, but the visual structure is misleading and review-hostile.
- `clear fmt` leaves long `unsupportedRuby(...)` placeholders and unsupported Ruby comment blocks over 120 columns. That is partly a ruby-to-clear placeholder problem, but formatter output does not produce a reviewable migration artifact from those placeholders.
