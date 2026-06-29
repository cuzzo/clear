<!-- GENERATED FILE. Source: tools/stdlib_docs.rb. -->

# Files, Paths, And IO

> [!WARNING]
> This is the current **planned** CLEAR stdlib design. Full stdlib
> implementation and stabilization are not planned until v0.3. Treat these
> pages as design direction, not as a compatibility promise.


Status: `planned`, `self-host required`.

File and network IO should be high-level by default. Users should not need
Java-style object stacks or Zig-style explicit buffer plumbing for common
work.

## High-Level File API

| API | Status | Notes |
| --- | --- | --- |
| `fs.read(path)` | `self-host required` | Read full UTF-8 text. |
| `fs.readBytes(path)` | `self-host required` | Read full byte buffer. |
| `fs.readLines(path)` | `self-host required` | Read text and split lines. |
| `fs.write(path, content)` | `self-host required` | Write text or bytes. |
| `fs.append(path, content)` | `planned` | Tooling convenience. |
| `fs.exists?(path)` | `self-host required` | File or directory exists. |
| `fs.file?(path)` | `self-host required` | Regular file predicate. |
| `fs.dir?(path)` | `self-host required` | Directory predicate. |
| `fs.symlink?(path)` | `self-host required` | Symlink predicate. |
| `fs.size(path)` | `self-host required` | File size. |
| `fs.mtime(path)` | `self-host required` | File modified time. |
| `fs.list(path)` | `self-host required` | Directory entries; deterministic policy required. |
| `fs.glob(pattern)` | `self-host required` | Glob paths; deterministic policy required. |

```ruby clear illustrative
source = fs.read("src/ast/parser.cht");
lines = fs.readLines("src/ast/lexer.cht");
fs.write("build/report.txt", report);
```

## Stateful File API

Stateful handles exist for large inputs, streaming, explicit lifetime, and
performance-sensitive code. They should not be required for simple reads
and writes.

```ruby clear illustrative
file = fs.open("events.log");
recent = file.lines()
    |> SELECT { _.contains?("ERROR") }
    |> COLLECT_LIST;
```

## Path API

| API | Status | Notes |
| --- | --- | --- |
| `path.join(parts...)` | `self-host required` | Replacement for `File.join`. |
| `path.expand(path, base?)` | `self-host required` | Replacement for `File.expand_path`. |
| `path.basename(path, suffix?)` | `self-host required` | Replacement for `File.basename`. |
| `path.dirname(path)` | `self-host required` | Replacement for `File.dirname`. |
| `path.relative(from, to)` | `planned` | Tooling convenience. |

## Decisions

- Error/fallibility model for failed IO.
- Resource auto-close semantics for high-level helpers.
- Stream lifetime rules when a stream is derived from a file handle.
- Deterministic ordering for `list` and `glob`.
- Linux-first versus cross-platform path behavior for v0.3.
