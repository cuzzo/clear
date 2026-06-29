#!/usr/bin/env ruby
# frozen_string_literal: true

# Source-of-truth public stdlib docs.
#
# These heredocs are intentionally code-owned rather than hand-authored under
# docs/. That keeps the planned API close to the implementation/generator, and
# gives us a path toward rustdoc/godoc-style generated language docs without
# implying that broad stdlib packages are implemented yet.

require "fileutils"

module StdlibDocs
  ROOT = File.expand_path("..", __dir__)

  Page = Struct.new(:path, :body, keyword_init: true)

  WARNING = <<~'MD'
    > [!WARNING]
    > This is the current **planned** CLEAR stdlib design. Full stdlib
    > implementation and stabilization are not planned until v0.3. Treat these
    > pages as design direction, not as a compatibility promise.
  MD

  def self.page(path, body)
    Page.new(path: path, body: body)
  end

  PAGES = [
    page("stdlib.md", <<~MD),
      # CLEAR Standard Library

      #{WARNING}

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
    MD
    page("stdlib/principles.md", <<~MD),
      # Stdlib Design Principles

      #{WARNING}

      ## Core Goal

      The stdlib's first architectural goal is composability with CLEAR's
      effects, capabilities, and tense system.

      Stdlib APIs should compose across:

      - pure/stateless functions;
      - stateful handles such as files, sockets, scanners, builders, and streams;
      - capability-wrapped values such as `@locked`, `@shared`, and `@local`;
      - effectful boundaries such as file IO, network IO, process execution,
        time, randomness, allocation, and blocking;
      - tense-aware values, including snapshots, live state, historical values,
        derived state, and streamed/current values where the language supports
        them.

      The user should be able to start with a high-level stateless API and only
      add state, effects, capabilities, or tense-specific machinery when the
      program actually needs it.

      ## High-Level Default

      After composability, the stdlib's highest user-facing priority is to feel
      as high-level as possible.

      This is true even when a traditional systems language would consider the
      API too convenient. CLEAR should expose Ruby/Elixir-level ergonomics by
      default and expose systems-level detail only when that detail is needed
      for correctness, performance, or capability control.

      We deviate from high-level interfaces for major flaws:

      - hidden unbounded memory growth in common usage;
      - impossible or misleading resource lifetime semantics;
      - data races or capability violations;
      - effect/capability behavior that the compiler cannot track;
      - performance cliffs that are large, common, and hard to diagnose;
      - APIs that make deterministic compiler output unreliable;
      - APIs that prevent a lower-level zero-cost path from existing.

      Ordinary systems-language preference is not enough by itself. "Zig would
      make the allocator explicit" or "Java would force a stream object" may be
      true, but those are not automatically good CLEAR user interfaces.

      ## IO And Streams

      File and network IO are the test case. CLEAR should not make ordinary IO
      as hard as Java or Zig.

      ```ruby clear illustrative
      text = fs.read("config.clear") OR RAISE;
      lines = fs.readLines("users.txt") OR RAISE;
      fs.write("out.txt", report) OR RAISE;
      ```

      Pipelines should default to using streams internally where that is the
      efficient strategy, especially for IO and large inputs. A pipeline can be
      collected implicitly by its destination type, or explicitly with a
      terminal such as `COLLECT_LIST`, `COLLECT_SET`, `COLLECT_MAP`, or
      `AS_STREAM`.

      ```ruby clear illustrative
      users = (fs.readLines("users.csv") OR RAISE)
          |> MAP { parseUser(_) }
          |> SELECT { _.active?() };
      ```

      The implementation may stream `users.csv` line by line. Because the
      assignment target is a list, the final value collects into that list.

      Users who want a stream, map, set, or another collection request it
      explicitly:

      ```ruby clear illustrative
      active_stream = (fs.readLines("users.csv") OR RAISE)
          |> MAP { parseUser(_) }
          |> SELECT { _.active?() }
          |> AS_STREAM;

      users_by_id = (fs.readLines("users.csv") OR RAISE)
          |> MAP { parseUser(_) }
          |> COLLECT_MAP { _.id => _ };

      unique_domains = (fs.readLines("emails.txt") OR RAISE)
          |> MAP { domainOf(_) }
          |> COLLECT_SET;
      ```

      The exact names are not final. The principle is final: stream internally
      where practical, collect from the explicit terminal or destination type,
      and never insert hidden sorts or other semantic work during collection.

      Ordering is explicit. Directory scans and globbing should be unsorted
      streams unless the user asks otherwise:

      ```ruby clear illustrative
      files = fs.glob("src/**/*.cht") OR RAISE;
      sorted = files |> ORDER_BY _;
      ```

      A future `SORT` shorthand may sort by the singular value, but that
      depends on the traits/interfaces or duck-typed ordering decision. Today
      `ORDER_BY` is the explicit sortable pipeline operator.

      ## Key Decisions Before Self-Host Implementation

      1. Confirm pipeline result defaults: stream internally where practical;
         collect according to explicit terminal or destination type.
      2. Choose explicit collection target syntax: `AS_STREAM`, `COLLECT_LIST`,
         `COLLECT_MAP`, `COLLECT_SET`, and typed collection targets.
      3. Define the named error taxonomy and future `Result` relationship;
         prototype stdlib APIs use native `!T` fallibility and `OR`
         propagation.
      4. Decide which effects are public stdlib contracts for self-host
         packages: file read/write, process/env, network read/write, time,
         random, allocation, blocking, and extern.
      5. Decide package capability permissions for files, network, processes,
         environment, clocks, and randomness.
      6. Decide resource lifetime and stream lifetime rules.
      7. Decide the stateless/stateful naming convention.
      8. Decide the string/bytes split and deterministic ordering defaults.
    MD
    page("stdlib/collections.md", <<~MD),
      # Collections And Pipelines

      #{WARNING}

      Status: `planned`, `self-host required`.

      Collections should feel like Ruby and Elixir at the call site while still
      giving the compiler enough information to track allocation, mutation,
      ownership, effects, and capability use.

      ## Planned Types

      | Type | Status | Notes |
      | --- | --- | --- |
      | Slice | `prototype` | Borrowed view over contiguous values. |
      | List/vector | `intrinsic today` | Growable contiguous collection. |
      | Map/hash | `intrinsic today` | Hash map; deterministic views required for compiler output. |
      | Set | `intrinsic today` | Hash set; deterministic views required for compiler output. |
      | Range | `prototype` | Numeric iteration and slicing. |
      | Pool/slab | `intrinsic today` | Stable handles for compiler/runtime structures. |
      | Queue/deque | `planned` | Add when compiler or scheduler code needs it. |

      ## Planned Transforms

      | API | Status | Behavior |
      | --- | --- | --- |
      | `each` | `self-host required` | Side-effect iteration, returns `Void`. |
      | `map` | `self-host required` | New list from final block expression. |
      | `select` / `filter` | `self-host required` | Keeps values where predicate is true. |
      | `reject` | `self-host required` | Inverse filter. |
      | `filterMap` | `self-host required` | Maps to `?T`, keeps non-nil values. |
      | `flatMap` | `self-host required` | Maps to collections and flattens. |
      | `reduce` / `fold` | `self-host required` | Explicit accumulator. |
      | `any?`, `all?` | `self-host required` | Short-circuit predicates. |
      | `find` | `self-host required` | Returns `?T`. |
      | `sum`, `count` | `self-host required` | Numeric and predicate aggregation. |
      | `ORDER_BY` | `self-host required` | Explicit sort by key expression. |
      | `keys`, `values`, `pairs` | `self-host required` | Map traversal; explicit ordered variants where output order matters. |
      | `indexed` | `self-host required` | Replacement for Ruby `each_with_index`. |
      | `withObject` / `foldInto` | `self-host required` | Replacement for Ruby `each_with_object`. |

      ## Pipeline Result Defaults

      Pipelines may stream internally, but collection is determined by explicit
      terminal or destination type. A `~T[]` destination keeps a stream; a
      `T[]` or `T[]@list` destination collects to a list; a `HashMap<K,V>`
      destination collects to a map if the pipeline shape supplies keys.

      ```ruby clear illustrative
      names: String[] = users
          |> SELECT { _.active?() }
          |> MAP { _.name };

      names_stream: ~String[] = users
          |> SELECT { _.name };
      ```

      Other result shapes are explicit:

      ```ruby clear illustrative
      users_by_id = users
          |> COLLECT_MAP { _.id => _ };

      unique_names = users
          |> MAP { _.name }
          |> COLLECT_SET;
      ```

      ## Decisions

      - Exact syntax for `AS_STREAM`, `COLLECT_LIST`, `COLLECT_MAP`, and
        `COLLECT_SET`.
      - How `SORT` differs from `ORDER_BY` after ordering traits/interfaces are
        designed.
      - Generic specialization without importing a class/trait/interface model.
      - Mutating operation names for `map!`, `<<`, `[]=`, and update forms.
    MD
    page("stdlib/files-and-io.md", <<~MD),
      # Files, Paths, And IO

      #{WARNING}

      Status: `planned`, `self-host required`.

      File and network IO should be high-level by default. Users should not need
      Java-style object stacks or Zig-style explicit buffer plumbing for common
      work.

      ## High-Level File API

      | API | Status | Notes |
      | --- | --- | --- |
      | `fs.read(path)` | `prototype`, `self-host required` | Read full UTF-8 text, returns `!String`. |
      | `fs.readBytes(path)` | `planned`, `self-host required` | Read full byte buffer. |
      | `fs.readLines(path)` | `planned`, `self-host required` | Target return: `!~String[]`, a fallible stream of lines. |
      | `fs.write(path, content)` | `prototype`, `self-host required` | Write text, returns `!Void`. |
      | `fs.append(path, content)` | `planned` | Tooling convenience. |
      | `fs.exists?(path)` | `self-host required` | File or directory exists. |
      | `fs.file?(path)` | `self-host required` | Regular file predicate. |
      | `fs.dir?(path)` | `self-host required` | Directory predicate. |
      | `fs.symlink?(path)` | `self-host required` | Symlink predicate. |
      | `fs.size(path)` | `prototype`, `self-host required` | File size, returns `!Int64`; current wrapper converts the old sentinel intrinsic to fallibility. |
      | `fs.mtime(path)` | `self-host required` | File modified time. |
      | `fs.list(path)` | `planned`, `self-host required` | Unsorted stream of directory entries. |
      | `fs.glob(pattern)` | `planned`, `self-host required` | Unsorted stream of matching paths. |

      ```ruby clear illustrative
      source = fs.read("src/ast/parser.cht") OR RAISE;
      lines = fs.readLines("src/ast/lexer.cht") OR RAISE;
      fs.write("build/report.txt", report) OR RAISE;

      ordered_files = (fs.glob("src/**/*.cht") OR RAISE)
          |> ORDER_BY _;
      ```

      The current `pkg:fs` prototype can compile `read`, collected
      `readLines`, `write`, and fallible `size` over existing intrinsics. The
      desired `readLines(path) RETURNS !~String[]` surface is blocked on
      parser/type support for a fallible stream container.

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
      - `ORDER_BY` versus future `SORT` shorthand once ordering
        traits/interfaces are designed.
      - Linux-first versus cross-platform path behavior for v0.3.
    MD
    page("stdlib/strings-and-bytes.md", <<~MD),
      # Strings And Bytes

      #{WARNING}

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
    MD
    page("stdlib/tooling.md", <<~MD),
      # JSON, CLI, Process, And Environment

      #{WARNING}

      Status: `planned`, `self-host required` for JSON and CLI basics.

      Compiler self-hosting needs enough tooling support to parse options,
      read/write metadata, run subprocesses for tests/build steps, and inspect
      the environment. These APIs must be high-level by default but visible to
      the effect/capability system.

      ## JSON

      | API | Status | Notes |
      | --- | --- | --- |
      | `Json.parse(text)` | `self-host required` | Dynamic JSON value first; typed decode later. |
      | `Json.generate(value)` | `self-host required` | Stable object ordering for compiler metadata. |
      | `Json.prettyGenerate(value)` | `self-host required` | Tooling output. |

      ```ruby clear illustrative
      config = Json.parse(fs.read("clear.json"));
      fs.write("build/metadata.json", Json.prettyGenerate(metadata));
      ```

      ## CLI

      | API | Status | Notes |
      | --- | --- | --- |
      | `argv` | `intrinsic today` | Current process arguments. |
      | `Cli.parse(spec, argv)` | `self-host required` | Typed option parser. |

      ```ruby clear illustrative
      opts = Cli.parse([
          Cli.flag("verbose"),
          Cli.option("output", type: String),
      ], argv);
      ```

      ## Process And Environment

      | API | Status | Notes |
      | --- | --- | --- |
      | `env.get(name)` | `planned` | Environment read effect. |
      | `env.set(name, value)` | `planned` | Environment write effect. |
      | `process.currentDirectory()` | `self-host required` | Current working directory. |
      | `Command{ argv, env, cwd }` | `planned` | Process description. |
      | `process.run(command)` | `planned` | Spawn and return status. |
      | `process.capture(command)` | `planned` | Spawn and capture output/status. |

      ## Decisions

      - JSON dynamic value representation.
      - Stable map/object ordering during generation.
      - CLI option spec syntax.
      - Package permissions for env/process access.
    MD
    page("stdlib/testing.md", <<~MD),
      # Testing And Diagnostics

      #{WARNING}

      Status: `prototype`, `self-host required`.

      `pkg:testing` exists today as a package-resolution smoke test. The real
      package should support compiler and stdlib oracle testing before broad
      self-host work depends on it.

      ## Planned Testing API

      | API | Status | Notes |
      | --- | --- | --- |
      | `ASSERT` | `planned` | Core assertion. |
      | `assertEqual(expected, actual)` | `self-host required` | Equality with useful diffs. |
      | `assertClose(expected, actual, tolerance)` | `planned` | Approximate float assertions. |
      | `expectError` | `self-host required` | Compile/runtime error assertions. |
      | Fixtures | `self-host required` | Test data files and temp dirs. |
      | Golden/oracle helpers | `self-host required` | Compiler output and transpiler tests. |
      | Test filtering | `planned` | CLI runner support. |
      | Leak/profile hooks | `planned` | Runtime integration. |

      ```ruby clear illustrative
      TEST "translates simple pipeline" ->
          clear = rubyToClear("list.map { |x| x + 1 }");
          assertEqual("list |> MAP { (_ + 1) };", clear);
      END
      ```

      ## Diagnostics

      Diagnostics should share formatting, source-span, and diff helpers with
      tests. Compiler output needs stable ordering and deterministic rendering.

      ## Decisions

      - Test declaration syntax: compiler syntax, library calls, or mixed.
      - How expected compiler errors are represented.
      - Golden file update workflow.
      - How much leak/profile machinery belongs in `pkg:testing`.
    MD
    page("stdlib/deferred.md", <<~MD),
      # Deferred Stdlib Surfaces

      #{WARNING}

      These packages are important, but they should not block the first
      self-host stdlib prototype.

      ## Regex And Scanner

      Regex and scanner support are self-host relevant, but they are deferred
      for implementation planning because there is not yet a Zig stdlib fallback
      we can rely on.

      The design direction remains:

      - no Ruby-style global match state;
      - explicit `Match` values;
      - explicit scanner position/matched text;
      - unsupported regex constructs fail closed.

      ## Network

      TCP resources exist as intrinsics today, but broad network design is not
      self-host critical. Network APIs need package permissions and explicit
      `NETWORK_READ` / `NETWORK_WRITE` effects before they become public.

      ## Crypto, Compression, Archives, HTTP, TLS

      These are launch-quality stdlib candidates, not self-host blockers. They
      should wait until the core error/effect/capability/package model is
      stable enough that we can avoid redesigning them immediately.
    MD
  ].freeze

  def self.generate!(root: ROOT)
    docs_root = File.join(root, "docs")
    stdlib_dir = File.join(docs_root, "stdlib")

    FileUtils.rm_rf(stdlib_dir)
    FileUtils.mkdir_p(stdlib_dir)

    PAGES.each do |page|
      out = File.join(docs_root, page.path)
      FileUtils.mkdir_p(File.dirname(out))
      File.write(out, generated_header + page.body)
    end
  end

  def self.generated_header
    <<~'MD'
      <!-- GENERATED FILE. Source: tools/stdlib_docs.rb. -->

    MD
  end
end
