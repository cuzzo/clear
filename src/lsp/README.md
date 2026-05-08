# clear-lsp — CLEAR Language Server

A Language Server Protocol (LSP) implementation for the CLEAR
programming language. Drop the snippet below into your Neovim config
and you get diagnostics, hover docs, and quick-fix actions on
`.cht` files. Drives the same `Lexer → Parser → SemanticAnnotator`
pipeline the `clear` CLI uses, so behaviour matches `clear build`
exactly.

## What you'll get

- **Squiggles** on every error, with the registry code shown
  (`UNDEFINED_VAR`, `WITH_RESTRICT_NEEDS_MUTABLE`, etc.).
- **Hover popups** (default key `K`) with the registry's summary,
  cause, fix hint, and a worked bad-vs-good example pulled from the
  test suite.
- **Quick-fix menu** for the 9 fixable findings — one keypress
  inserts `MUTABLE`, replaces `@canSmash` with `@service`, wraps
  with `CAST`, etc.

---

## Step 1 — Verify prerequisites

You need Ruby ≥ 3.0 and bundler installed:

```sh
ruby --version          # → 3.0 or newer
bundler --version       # → any 2.x
```

If you don't have bundler: `gem install bundler`.

Then from the repo root, install the gems:

```sh
cd /path/to/cheat       # wherever you cloned this repo
bundle install
```

This is a one-time setup. Skip if you already run `clear` from this
checkout.

## Step 2 — Verify the binary works (terminal smoke test)

Before touching Neovim, confirm the LSP server actually runs. From
the repo root:

```sh
bundle exec bin/clear-lsp --help
```

You should see:

```
Usage: clear-lsp [--log-level=debug|info|warn|error]
```

If you get a Ruby error here (missing gem, version mismatch, syntax
error), fix it before moving on — the Neovim config can't make a
broken binary work.

For a deeper smoke test that actually exercises the protocol, the
test suite drives the binary end-to-end:

```sh
bundle exec rspec spec/lsp/server_integration_spec.rb --tag integration
```

Six tests should pass in about 2 seconds. If they pass, the binary
works; any Neovim issues from here are config, not code.

## Step 3 — Find your Neovim config directory

Run `:echo stdpath('config')` inside Neovim. On most systems it'll
be one of:

- Linux/macOS: `~/.config/nvim/`
- Windows: `~\AppData\Local\nvim\`

Inside that directory, your main config is `init.lua` (or
`init.vim` on older setups — the Lua block below assumes Lua. If
you're on `init.vim`, wrap the snippet in `lua << EOF ... EOF`).

## Step 4 — Add the LSP setup

There are two paths depending on how you manage your Neovim config.
Both work. **The first is plain Neovim with no plugin manager.** The
second is for users on lazy.nvim or similar.

### Plain Neovim (no plugin manager) — recommended for trying it out

Add this to your `init.lua`. **Replace `/absolute/path/to/cheat`
with your actual repo path** (run `pwd` in the repo to get it):

```lua
---------------------------------------------------------------------
-- CLEAR (.cht) language support
---------------------------------------------------------------------

-- 1. Tell Neovim what filetype `.cht` files are.
vim.filetype.add({ extension = { cht = "clear" } })

-- 2. Auto-start the LSP whenever a CLEAR buffer opens.
local clear_lsp_root = "/absolute/path/to/cheat"  -- ← edit this
vim.api.nvim_create_autocmd("FileType", {
  pattern = "clear",
  callback = function()
    vim.lsp.start({
      name = "clear-lsp",
      cmd  = {
        "bundle", "exec",
        clear_lsp_root .. "/bin/clear-lsp",
        "--log-level=info",
      },
      cmd_cwd  = clear_lsp_root,
      root_dir = vim.fs.dirname(
        vim.fs.find({ ".git", "Gemfile" }, { upward = true })[1]
      ) or vim.fn.getcwd(),
    })
  end,
})

-- 3. Default LSP keymaps (only active in CLEAR buffers).
vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(args)
    local opts = { buffer = args.buf, silent = true }
    vim.keymap.set("n", "K",          vim.lsp.buf.hover,         opts)
    vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action,   opts)
    vim.keymap.set("n", "[d",         vim.diagnostic.goto_prev,  opts)
    vim.keymap.set("n", "]d",         vim.diagnostic.goto_next,  opts)
    vim.keymap.set("n", "<leader>e",  vim.diagnostic.open_float, opts)
  end,
})

-- 4. Make diagnostics actually visible. Neovim's defaults are
--    minimal — show inline virtual text and gutter signs.
vim.diagnostic.config({
  virtual_text  = true,
  signs         = true,
  underline     = true,
  update_in_insert = false,        -- don't recompute mid-keystroke
  severity_sort = true,
})
```

Save the file, then restart Neovim. The next section verifies it.

### lazy.nvim users

If you use lazy.nvim or another plugin manager, drop this in a
`lua/plugins/clear.lua` (or wherever your plugin specs live):

```lua
return {
  -- Bootstrap the CLEAR LSP. No external plugin needed; we just
  -- register the filetype + autocmd from inside the spec.
  {
    name = "clear-lsp",
    dir  = vim.fn.stdpath("data") .. "/lazy/clear-lsp-noop",  -- placeholder
    lazy = false,
    config = function()
      local clear_lsp_root = "/absolute/path/to/cheat"  -- ← edit

      vim.filetype.add({ extension = { cht = "clear" } })

      vim.api.nvim_create_autocmd("FileType", {
        pattern = "clear",
        callback = function()
          vim.lsp.start({
            name = "clear-lsp",
            cmd  = {
              "bundle", "exec",
              clear_lsp_root .. "/bin/clear-lsp",
              "--log-level=info",
            },
            cmd_cwd  = clear_lsp_root,
            root_dir = vim.fs.dirname(
              vim.fs.find({ ".git", "Gemfile" }, { upward = true })[1]
            ) or vim.fn.getcwd(),
          })
        end,
      })

      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(args)
          local opts = { buffer = args.buf, silent = true }
          vim.keymap.set("n", "K",          vim.lsp.buf.hover,         opts)
          vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action,   opts)
          vim.keymap.set("n", "[d",         vim.diagnostic.goto_prev,  opts)
          vim.keymap.set("n", "]d",         vim.diagnostic.goto_next,  opts)
          vim.keymap.set("n", "<leader>e",  vim.diagnostic.open_float, opts)
        end,
      })

      vim.diagnostic.config({
        virtual_text  = true,
        signs         = true,
        underline     = true,
        severity_sort = true,
      })
    end,
  },
}
```

## Step 5 — Verify it's working in Neovim

Open a CLEAR file with a deliberate error. From the repo root:

```sh
nvim transpile-tests/01_smoke.cht
```

You should see no diagnostics (it's valid CLEAR). Now try a broken
file. Save this somewhere as `/tmp/broken.cht`:

```clear
FN main() RETURNS Void ->
  _ = doesNotExist;
  x = 5;
  WITH RESTRICT x { _ = x; }
END
```

Open it: `nvim /tmp/broken.cht`. Within ~1 second:

1. **Diagnostic squiggle** under `doesNotExist` and on the `WITH
   RESTRICT x` line.
2. Press **`K`** with the cursor on `doesNotExist` — a popup
   appears with `**[error] UNDEFINED_VAR**`, the cause, and the fix
   hint.
3. Move the cursor to the `x` in `RESTRICT x` and press
   **`<leader>ca`** — a menu offers "Declare 'x' as MUTABLE at its
   binding site (line 3).". Accepting it inserts `MUTABLE ` at line
   3 and the diagnostic vanishes.

If all three work, you're done.

## Step 6 — Troubleshooting

### "Nothing happens when I open a .cht file"

Run `:LspInfo` inside Neovim. If `clear-lsp` isn't listed, the
autocmd didn't fire. Check:

- `:set filetype?` — should say `clear`. If it says `cht` or empty,
  the `vim.filetype.add` call didn't run; verify the snippet
  actually loaded (try `:lua print("clear-lsp config loaded")` at
  the top to confirm).
- The path in `cmd` exists and is executable: `:! ls -la
  /absolute/path/to/cheat/bin/clear-lsp` — should show `-rwxr-xr-x`.

### "Server is attached but no diagnostics appear"

Turn on Neovim's LSP debug log to see what's happening over the
wire:

```vim
:lua vim.lsp.set_log_level("debug")
:LspLog
```

Look for:

- `[ERROR]` lines pointing at framing problems.
- A long pause with no `publishDiagnostics` after `didOpen` —
  usually means the analyzer threw something we don't handle. The
  server's own log goes to stderr; in Neovim, stderr appears in
  `:LspLog` too (look for `[clear-lsp/error]` lines).

### "I see `bundler/setup` errors when starting"

The binary needs to run inside the repo's bundler environment. Two
fixes:

1. Confirm `cmd_cwd` in the config is set to the repo root (where
   `Gemfile` lives). Without it, Bundler can't find `Gemfile.lock`.
2. Confirm the Ruby on `$PATH` in your shell matches the one Neovim
   uses. If you use `rbenv` or `asdf`, sometimes Neovim launches
   under a different Ruby. Test by adding `RBENV_VERSION=3.2.0` (or
   your version) to the `cmd` env, or use a wrapper script.

If `bundle exec` itself errors with "could not find gem ostruct":

```sh
cd /path/to/cheat
bundle update ostruct
```

### "Hover or code action does nothing"

Both rely on cached findings from the most recent analysis pass. If
the file has no errors, hover returns `null` (popup dismissed) and
code action returns `[]` (empty menu). Try a deliberately-broken
file like the example in step 5.

### "I want to see the LSP's own logs"

The server logs to stderr at the `--log-level` you specify. In
Neovim, those appear in `:LspLog` interleaved with the client's
own messages. Bump verbosity in the `cmd` array:

```lua
cmd = { "bundle", "exec", clear_lsp_root .. "/bin/clear-lsp",
        "--log-level=debug" }
```

`debug` shows every JSON-RPC request/response method name; `info`
shows lifecycle events plus per-document diagnostic counts; `warn`
and `error` are quiet.

### "I want a fresh server"

`:LspRestart` (Neovim ≥ 0.10) or `:lua vim.lsp.stop_client(
vim.lsp.get_active_clients()[1].id)` then re-open the buffer.

---

## Capabilities advertised

```
{
  textDocumentSync:   1,                              -- full sync
  hoverProvider:      true,
  codeActionProvider: { codeActionKinds: ["quickfix", "refactor"] }
}
```

## Architecture

```
neovim ─[stdio JSON-RPC]─→ bundle exec bin/clear-lsp
                              │
                              ├─ src/lsp/rpc.rb           Content-Length framing
                              ├─ src/lsp/server.rb        Message loop + dispatch
                              ├─ src/lsp/document_store.rb open buffers + cached findings
                              ├─ src/lsp/analyzer.rb      Lexer→Parser→Annotator
                              │     wraps FixCollector to capture findings
                              │     mirrors the lambda used by `clear fix`
                              ├─ src/lsp/diagnostics.rb   Finding → LSP::Diagnostic
                              ├─ src/lsp/code_actions.rb  Fix      → LSP::CodeAction
                              ├─ src/lsp/hover.rb         Diagnostic+ → markdown
                              └─ src/lsp/position.rb      bytes ↔ UTF-16 columns
```

Each module is independently tested under `spec/lsp/` with 100% line
coverage (431/431 lines). The integration spec drives the actual
binary end-to-end.

## VS Code

A formal extension hasn't been published yet. If you want to set it
up manually, the generic `vscode-languageserver-client` config with
`cmd: ["bundle", "exec", "/path/to/bin/clear-lsp"]` and
`documentSelector: [{ scheme: "file", language: "clear" }]` works.
PRs welcome.

## Out of scope (future work)

- Completion (`textDocument/completion`)
- Go-to-definition / rename / references / workspace symbols
- Semantic tokens
- Multi-file `REQUIRE` graph: editing one file should re-analyse
  files that import it
- Incremental sync (full sync is fast enough for now)

Each is additive — adding any won't break the MVP's behaviour.
