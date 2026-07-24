# giga watch

`giga watch` keeps a repository's evidence database current by analysing and
ingesting every new commit, and coordinates with readers so nobody sees a
half-written database.

## What it does

```
giga watch [--repo .] [--db .giga/gigasail.db] [--profile analyse]
           [--interval 2] [--trust-current-config] [--once]
```

The watcher polls `HEAD`. When `HEAD` advances to a commit it has not yet
processed, it:

1. Takes the `.giga/` coordination lock for that commit (`operation = analyse`).
2. Runs the analysis profile and ingests the run into the database
   (`analyse --ingest`, i.e. "ci then sync").
3. Releases the lock.

- A tick that finds the lock already held by a live peer is **Busy**: the commit
  is left for a later poll once the peer releases.
- A tick whose analysis fails logs the error and advances past the commit, so a
  single bad commit never spins the loop; the next new commit is still attempted.
- `--once` processes the current `HEAD` and exits (scripting and tests).

## The `.giga/` lock

`giga_core::lock` implements a single PID-bearing lock file, `.giga/lock.json`:

```json
{ "pid": 12345, "commit": "<40-hex>", "operation": "analyse", "started_at": 1720000000 }
```

- **Race-free acquisition.** The record is written to a per-call temp file, then
  atomically `hard_link`ed into place. `link(2)` fails with `EEXIST` when the
  lock is held, so a peer never observes a half-written lock.
- **Zombie reclaim.** A lock left by a dead process is detected with
  `kill(pid, 0)` (ESRCH) and reclaimed automatically.
- **RAII release.** Dropping the `GigaLock` removes the file, but only if this
  process is still the recorded owner.

This is what stops a second `giga watch` — or any writer — from indexing the
database at the same time as an in-flight run.

## How readers coordinate (`giga diff`, MCP)

Readers do not take the lock; they consult it via
`giga_core::lock::wait_while_locked_for(dir, commit, ...)`:

- If the lock is held **for the exact commit** the reader is about to render,
  the reader waits (polling) until analysis of that commit finishes, so it shows
  complete evidence. `giga diff` prints `waiting for analysis of <commit>...`.
- If the lock is free, or held **for a different commit**, the reader proceeds
  immediately. Diffing a previously analysed commit just shows it.
- Waiting is bounded (10 min ceiling); past that the reader renders whatever is
  available rather than blocking forever.

`giga diff` applies this before preparing the plan (every output format). The
MCP server applies it at the start of each tool call (off the async executor via
`spawn_blocking`), so tool results reflect a fully ingested database.

## Launching the servers

`giga watch` only maintains the database. Serve it separately:

- Web UI: `giga-ui serve --db .giga/gigasail.db --repo .`
- Language server: `giga-ui lsp --db .giga/gigasail.db --repo .`
- MCP (for coding agents): `giga-ui mcp --db .giga/gigasail.db --repo .`

A typical local setup runs `giga watch` in the background and one of the
`giga-ui` servers in the foreground; the lock keeps them consistent.
