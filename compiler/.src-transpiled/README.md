# Pristine ruby-to-clear output (reference only -- never built)

Regenerate:

    ruby gems/ruby-to-clear/exe/ruby-to-clear compiler/ruby/<path>.rb > compiler/.src-transpiled/<path>.clear

Snapshotted 2026-07-31 from the then-current `compiler/ruby` and ruby-to-clear.
Exists so the manual-fix cost of self-hosting can be measured as a diff against
`compiler/src` once the parser reaches MessagePack parity.

Caveat: `compiler/src` predates this snapshot and was produced by an earlier
ruby-to-clear against an earlier `compiler/ruby`, and has since been refactored
by hand (notably 2f40b8e924, which dissolved the generated package cycles). A
diff taken today therefore mixes transpiler-version drift with genuine manual
fixes. Fixes made from this snapshot forward are the clean signal.

`compiler_regex.clear` and `ast/schemas.clear` have no Ruby source; they are
hand-written and absent here.
