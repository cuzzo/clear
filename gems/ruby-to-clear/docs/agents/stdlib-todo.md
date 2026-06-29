# CLEAR Stdlib TODO For Ruby-to-CLEAR Migration

Audit date: 2026-06-29.

This file lists CLEAR-side stdlib functionality needed by the Ruby-to-CLEAR
self-hosting path, ordered by migration importance. The transpiler should map to
these primitives only when the call shape is direct and efficient. It should not
grow a Ruby compatibility runtime.

## P0: Files, Directories, And Paths

Audit evidence:

- `File.exist?`: 50
- `File.join`: 50
- `File.expand_path`: 25
- `File.readlines`: 22
- `File.read`: 17
- `File.basename`: 13
- `File.dirname`: 10
- `Dir.glob`: 8
- `Dir.exist?`: 6
- `Dir.pwd`: 3
- Low-frequency but required: `File.foreach`, `File.mtime`, `File.write`,
  `File.binwrite`, `File.delete`, `File.file?`, `File.readlink`,
  `File.symlink`, `File.symlink?`

Needed CLEAR primitives:

| CLEAR primitive | Ruby shape |
| --- | --- |
| `readFile(path)` | `File.read(path)` |
| `readLines(path)` or `readFile(path).split("\n")` | `File.readlines(path)` |
| `forEachLine(path, fn)` or line iterator | `File.foreach(path) { ... }` |
| `writeFile(path, content)` | `File.write`, `File.binwrite` |
| `fileExists?(path)` | `File.exist?`, `File.exists?` |
| `regularFile?(path)` | `File.file?` |
| `deleteFile(path)` | `File.delete` |
| `fileModifiedTime(path)` | `File.mtime` |
| `readLink(path)` | `File.readlink` |
| `createSymlink(target, link)` | `File.symlink` |
| `symlinkExists?(path)` | `File.symlink?` |
| `joinPath(parts...)` | `File.join` |
| `expandPath(path, base?)` | `File.expand_path` |
| `baseName(path, suffix?)` | `File.basename` |
| `dirName(path)` | `File.dirname` |
| `globPaths(pattern)` | `Dir.glob` |
| `dirExists?(path)` | `Dir.exist?`, `Dir.exists?` |
| `listDir(path)` | `Dir.children` |
| `listAll(path)` | `Dir.entries` |
| `currentDirectory()` | `Dir.pwd` |

Required semantics:

- Deterministic path normalization across Linux/macOS where practical.
- Explicit error behavior: return `!T`/raise CLEAR error for failed IO instead
  of silently mimicking Ruby exceptions.
- Stable ordering for `globPaths`, `listDir`, and `listAll`.
- Text and binary reads should be explicit if CLEAR distinguishes them.

## P0: Collections And Enumerable Pipelines

Audit evidence:

- `Set.new`: 251 in audit output, 329 by raw grep.
- `Set.[]`: 32.
- High-frequency block shapes: `each` (925), `map` (338), `any?` (126),
  `each_with_index` (73), `filter_map` (64), `select` (55), `flat_map` (52),
  `each_value` (49), `find` (46), `reject` (44), `each_with_object` (36),
  `all?` (33), `sort_by` (31), `each_pair` (25), `map!` (20),
  `reverse_each` (17), `sum` (16), `each_key` (15), `count` (10),
  `transform_values` (10).

Needed CLEAR primitives:

| CLEAR primitive | Ruby shape |
| --- | --- |
| `Set[]` / set literal | `Set.new`, `Set[]` |
| `distinct(collection)` or `collection |> DISTINCT _` | `Set.new(collection)` |
| `contains?(collection, value)` | `include?`, `member?`, `key?` |
| `keys(map)` / `values(map)` / `pairs(map)` | `each_key`, `each_value`, `each_pair` |
| `mapValues(map, fn)` | `transform_values` |
| `filterMap(collection, fn)` | `filter_map` |
| `flatMap(collection, fn)` | `flat_map` |
| `find(collection, fn)` | `find`, `detect` |
| `any?(collection, fn)` / `all?(collection, fn)` | `any?`, `all?` |
| `sum(collection, fn?)` / `count(collection, fn?)` | `sum`, `count` |
| `sortBy(collection, fn)` | `sort_by` |
| `reverse(collection)` / reverse iterator | `reverse_each` |
| indexed iterator | `each_with_index` |
| accumulator iterator | `each_with_object` |

Required semantics:

- Deterministic set/map iteration where compiler output depends on ordering.
- Explicit nil handling for `find`, `filter_map`, and map lookups.
- Allocation behavior should be visible in types/effects where CLEAR tracks it.
- Mutation forms such as `map!` should map to explicit mutation or be rejected.

## P1: Strings, Regex, And Scanning

Audit evidence:

- `RegularExpressionNode`: 183 Prism nodes.
- `InterpolatedStringNode`: 1,812 Prism nodes.
- `Regexp.escape`: 12.
- `Regexp.last_match`: 6.
- `Regexp.new`: 1.
- `StringScanner.new`: 2.
- Common string calls include `to_s`, `include?`, `empty?`, `length`, `join`,
  `strip`, `start_with?`, `end_with?`, `index`, `lines`, `gsub`, and `sub`.

Needed CLEAR primitives:

| CLEAR primitive | Ruby shape |
| --- | --- |
| `escapeRegex(string)` | `Regexp.escape` |
| regex literal value or compiled pattern | `/.../`, `Regexp.new` safe subset |
| explicit match result | `match`, captures, replacement helpers |
| scanner type with position | `StringScanner.new` |
| `scan`, `peek`, `eos?`, `matched`, `pos` operations | lexer/scanner code |
| `trim`, `startsWith?`, `endsWith?`, `indexOf`, `splitLines` | string helpers |
| literal replacement | safe `sub`/`gsub` without Ruby regex globals |

Required semantics:

- No implicit global match state. `Regexp.last_match`, `$1`, and related Ruby
  behavior should be refactored to explicit match results.
- Regex support can be deliberately smaller than Ruby's as long as unsupported
  patterns fail closed.
- Scanner APIs should be designed for compiler lexing, not broad Ruby
  `StringScanner` compatibility.

## P1: JSON

Audit evidence:

- `JSON.parse`: 3.
- `JSON.generate`: 1.
- `JSON.pretty_generate`: 1.

Needed CLEAR primitives:

| CLEAR primitive | Ruby shape |
| --- | --- |
| `parseJson(string)` | `JSON.parse` |
| `generateJson(value)` | `JSON.generate` |
| `prettyGenerateJson(value)` | `JSON.pretty_generate` |

Required semantics:

- Stable object field ordering for emitted compiler metadata where needed.
- Typed decode helpers are preferable to untyped dynamic maps once the target
  schema is known.

## P2: CLI And Process Helpers

Audit evidence:

- `OptionParser.new`: 1.
- No high-frequency `Open3` or process calls appeared in the audit, but build
  and tool hosting may need a small process surface later.

Needed CLEAR primitives:

| CLEAR primitive | Ruby shape |
| --- | --- |
| simple option parser | `OptionParser.new` safe subset |
| process exec with argv/env/cwd | future `Open3`/build helper needs |
| stdout/stderr capture | future tool hosting |

Required semantics:

- Prefer explicit typed option specs over Ruby-style parser blocks.
- Keep process execution out of the transpiler runtime; this belongs in a CLEAR
  stdlib/tooling package.

## P2: Time And Miscellaneous Host Values

Audit evidence:

- `File.mtime`: 2.
- `__FILE__` / source-file handling appears in receiver-kind audit as
  `SourceFileNode`.

Needed CLEAR primitives:

| CLEAR primitive | Ruby shape |
| --- | --- |
| file timestamp value | `File.mtime` |
| current source file constant | `__FILE__` |
| monotonic/current time if tooling needs it | future host helpers |

Required semantics:

- Prefer explicit timestamp/value types over Ruby `Time` compatibility.
- `__FILE__` should be a compile-time/source-location primitive if possible.
