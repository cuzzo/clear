<!-- GENERATED FILE. Source: tools/stdlib_docs.rb. -->

# CLEAR Standard Library

> [!WARNING]
> This is the current **planned** CLEAR stdlib design. Full stdlib
> implementation and stabilization are not planned until v0.3. Treat these
> pages as design direction, not as a compatibility promise.


These pages are generated from heredocs in `tools/stdlib_docs.rb`. Do not
edit the generated markdown directly; update the code-owned doc source and
run `ruby tools/gen_site.rb`.

The stdlib's first goal is composability with CLEAR's effects,
capabilities, and tense system. Its next priority is to feel as high-level
as possible, even when a traditional systems language would expose more
machinery by default.

## Package Specs

| Area | Page | Self-host relevance |
| --- | --- | --- |
| Design principles | [Principles](stdlib/principles.md) | Sets the API bias before implementation. |
| Collections and pipelines | [Collections](stdlib/collections.md) | Required for Ruby-to-CLEAR output and compiler passes. |
| Files, paths, and IO | [Files and IO](stdlib/files-and-io.md) | Required for compiler loading, build tooling, and diagnostics. |
| Strings and bytes | [Strings and Bytes](stdlib/strings-and-bytes.md) | Required for lexer/parser/compiler text work. |
| JSON, CLI, process, env | [Tooling](stdlib/tooling.md) | Required for compiler tools and metadata. |
| Testing and diagnostics | [Testing](stdlib/testing.md) | Required for oracle tests and self-host confidence. |
| Deferred surfaces | [Deferred](stdlib/deferred.md) | Regex/scanner/network/crypto and other work not first in line. |

## Status Tags

| Tag | Meaning |
| --- | --- |
| `planned` | Intended shape, not implemented or stable. |
| `prototype` | Some implementation exists, but the API may change. |
| `intrinsic today` | Exists as a compiler/runtime intrinsic rather than a source package. |
| `self-host required` | Needed for the compiler self-host path. |
| `stable` | Compatibility promise. No API on these pages is stable yet. |

## Design Bias

CLEAR should choose Ruby/Elixir-level convenience until that creates a
major correctness, performance, or security flaw. Systems-level controls
must exist, but ordinary file IO, pipelines, string work, and collection
transforms should not require users to start with handles, buffers,
allocators, or stream machinery.

Fallible stdlib APIs use CLEAR's `!T` fallible tense. If a caller does
not handle the error inline with `OR ...`, it bubbles through the caller's
fallible return path. We will not hide IO or parsing errors like Ruby.

Illustrative examples use `ruby clear illustrative` fences. They are
design examples and may not compile until the corresponding package moves
beyond `planned`.
