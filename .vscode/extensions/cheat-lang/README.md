# clear-lang — VS Code extension for CLEAR

Syntax highlighting + Language Server integration for the CLEAR
programming language (`.clear` files). Surfaces diagnostics, hover
documentation, and quick-fix code actions in VS Code, the same way
the Neovim setup does.

## What you'll get

- **Squiggles** on every error with the registry code shown.
- **Hover** (cursor on a diagnostic) — markdown popup with the
  registry's summary, cause, fix hint, and a worked bad-vs-good
  example pulled from the test suite.
- **Quick-fix menu** (Ctrl+. / Cmd+.) — choose from the available
  auto / interactive fixes; accepting one applies the edit.

## One-time setup (from the cheat repo root)

The extension lives inside the repo at
`.vscode/extensions/cheat-lang/`. Build the TypeScript client:

```sh
cd .vscode/extensions/cheat-lang
npm install
npm run compile
```

This produces `out/extension.js` (the entry point referenced by
`package.json`). The extension is now ready.

### How VS Code finds it

VS Code automatically loads extensions found in `.vscode/extensions/`
when you open the workspace. No manual install step needed beyond
`npm run compile`. Reload the VS Code window (Ctrl+Shift+P →
"Developer: Reload Window") to pick up the freshly-built extension.

## Verifying

Open any `.clear` file. The status bar should show "CLEAR" as the
language. Open the Output panel (Ctrl+Shift+U) and select
"CLEAR Language Server" from the dropdown — you should see startup
log lines from the server.

Try a deliberately-broken file:

```clear
FN main() RETURNS Void ->
  _ = doesNotExist;
  x = 5;
  WITH RESTRICT x { _ = x; }
END
```

You should see:

1. Squiggles under `doesNotExist` (line 2) and the `WITH RESTRICT x`
   line (line 4).
2. Hover the mouse over `doesNotExist` → tooltip with the registry
   markdown.
3. Cursor on the `x` of `RESTRICT x`, press Ctrl+. → menu offers
   "Declare 'x' as MUTABLE at its binding site (line 3).". Accept;
   the buffer updates.

## Settings

`clear.serverPath` (string, default `""`) — absolute path to
`bin/clear-lsp`. Defaults to auto-detecting from the extension's
install location, which works when the extension lives inside the
cheat repo. Set it explicitly when installing as a `.vsix` outside
the repo.

`clear.serverArgs` (array of string, default
`["--log-level=info"]`) — extra arguments passed to clear-lsp. Bump
to `--log-level=debug` for verbose protocol logs.

`clear.useBundleExec` (boolean, default `true`) — whether to
invoke the server via `bundle exec`. Set to false if your
environment has the right gems on `$LOAD_PATH` already (uncommon).

## Troubleshooting

- **"clear-lsp not found at /path"** — the auto-detection failed.
  Either move the extension to `.vscode/extensions/cheat-lang/`
  inside your cheat clone, or set `clear.serverPath` manually.
- **Server starts then stops immediately** — open the
  "CLEAR Language Server" output channel; the server's stderr
  appears there. Common causes: missing gems (`bundle install` in
  the repo root) or wrong Ruby version.
- **No diagnostics on a file with errors** — confirm the language
  is "CLEAR" in the status bar; if VS Code thinks it's plain text,
  the language registration didn't take. Try reloading the window.

## Files

```
.vscode/extensions/cheat-lang/
├── package.json                       — extension manifest
├── tsconfig.json                      — TypeScript config
├── language-configuration.json        — comments, brackets, indentation
├── README.md                          — this file
├── src/extension.ts                   — LSP client (TypeScript)
├── syntaxes/clear.tmLanguage.json     — syntax highlighting grammar
└── out/extension.js                   — compiled client (generated)
```

## Packaging as a .vsix (optional)

For distribution outside the repo, install `vsce` and package:

```sh
npm install -g @vscode/vsce
cd .vscode/extensions/cheat-lang
vsce package
```

Produces `clear-lang-0.2.0.vsix`. Install via "Extensions: Install
from VSIX..." in VS Code. Users will need to set `clear.serverPath`
manually since auto-detection won't find the binary.
