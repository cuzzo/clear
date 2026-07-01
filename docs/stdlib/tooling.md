<!-- GENERATED FILE. Source: tools/stdlib_docs.rb. -->

# JSON, CLI, Process, And Environment

> [!WARNING]
> This is the current **planned** CLEAR stdlib design. Full stdlib
> implementation and stabilization are not planned until v0.3. Treat these
> pages as design direction, not as a compatibility promise.


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
