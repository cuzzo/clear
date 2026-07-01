<!-- GENERATED FILE. Source: tools/stdlib_docs.rb. -->

# Strings And Bytes

> [!WARNING]
> This is the current **planned** CLEAR stdlib design. Full stdlib
> implementation and stabilization are not planned until v0.3. Treat these
> pages as design direction, not as a compatibility promise.


Status: `planned`, `self-host required`.

`String` is UTF-8 text. Byte buffers are byte data. The stdlib should keep
that distinction visible even when both are backed by `[]u8`.

## Planned String API

| API | Status | Notes |
| --- | --- | --- |
| `length` | `intrinsic today` | Exact string semantics still need naming clarity. |
| `bytes` | `intrinsic today` | Byte length. |
| `codepointCount` | `intrinsic today` | UTF-8 codepoint count. |
| `byteAt` | `intrinsic today` | Byte-level access. |
| `charAt` | `intrinsic today` | Codepoint/text access. |
| `substr` | `intrinsic today` | Slice/copy behavior depends on ownership. |
| `split`, `splitLines`, `join` | `self-host required` | Compiler text work. |
| `trim`, `startsWith?`, `endsWith?`, `contains?`, `indexOf` | `intrinsic today` | Search/predicate helpers. |
| `replace`, `downcase`, `upcase` | `intrinsic today` | Initial versions are byte/ASCII oriented. |
| `StringBuilder` | `planned` | Repeated concatenation without repeated copies. |
| `format` / interpolation | `planned` | Explicit allocation and formatting rules. |

```ruby clear illustrative
tokens = source.splitLines()
    |> MAP { _.trim() }
    |> REJECT { _.empty?() };
```

## Decisions

- Byte-indexed, codepoint-indexed, and grapheme-aware operation names.
- Whether `String` can hold invalid UTF-8.
- Byte buffer conversion rules.
- Builder ownership and allocation behavior.
