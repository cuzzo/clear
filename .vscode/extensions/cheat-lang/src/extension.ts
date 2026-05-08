// CLEAR Language Server VS Code client.
//
// Activates on `.cht` files (registered language id: "clear"), spawns
// `bundle exec bin/clear-lsp`, and wires the standard LSP client so
// VS Code surfaces:
//
//   * Diagnostics — squiggles on errors with the registry code.
//   * Hover — `K`-equivalent: cursor on a diagnostic shows the
//     registry markdown popup (cause, fix hint, bad/good example).
//   * Code actions — Ctrl+. (Cmd+. on macOS) opens the quick-fix
//     menu populated by FixableFinding's auto + interactive fixes.
//
// The server path is auto-detected when the extension is installed
// inside the cheat repo at `.vscode/extensions/cheat-lang/` — the
// extension walks up three levels to the repo root and finds
// `bin/clear-lsp` there. Override via the `clear.serverPath` setting
// when installing the extension as a portable .vsix that isn't
// shipped from inside the repo.

import * as fs   from "fs";
import * as path from "path";
import {
  workspace,
  window,
  ExtensionContext,
  Uri,
} from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export function activate(context: ExtensionContext) {
  const cfg = workspace.getConfiguration("clear");

  const serverPath = (cfg.get<string>("serverPath") || "").trim() ||
                     defaultServerPath(context.extensionPath);
  if (!fs.existsSync(serverPath)) {
    window.showErrorMessage(
      `clear-lsp not found at ${serverPath}. Set "clear.serverPath" in settings ` +
      `to point at your cheat repo's bin/clear-lsp.`
    );
    return;
  }

  const useBundleExec = cfg.get<boolean>("useBundleExec", true);
  const serverArgs    = cfg.get<string[]>("serverArgs", ["--log-level=info"]);
  const repoRoot      = path.dirname(path.dirname(serverPath));  // .../cheat/bin/clear-lsp → .../cheat

  // The CLEAR compiler requires `bundler/setup`, so by default we
  // launch via `bundle exec`. Fall back to direct invocation when
  // the user has the gems available globally.
  const command = useBundleExec ? "bundle"            : serverPath;
  const args    = useBundleExec
    ? ["exec", serverPath, ...serverArgs]
    : serverArgs;

  const serverOptions: ServerOptions = {
    command,
    args,
    transport: TransportKind.stdio,
    options: {
      cwd: repoRoot,  // bundler reads Gemfile from here
    },
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "clear" }],
    synchronize: {
      fileEvents: workspace.createFileSystemWatcher("**/*.cht"),
    },
    outputChannelName: "CLEAR Language Server",
  };

  client = new LanguageClient(
    "clear-lsp",
    "CLEAR Language Server",
    serverOptions,
    clientOptions
  );

  // Surface server stderr in the output channel so users can see
  // logs without leaving VS Code.
  client.start().catch((err) => {
    window.showErrorMessage(`clear-lsp failed to start: ${err.message}`);
  });
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}

// When `clear.serverPath` isn't set, find the LSP binary by walking
// up from the extension's own install location to the cheat repo
// root. This makes the in-repo install (.vscode/extensions/...)
// just work without configuration.
function defaultServerPath(extensionPath: string): string {
  // .vscode/extensions/cheat-lang → up 3 → repo root.
  const repoRoot = path.resolve(extensionPath, "..", "..", "..");
  return path.join(repoRoot, "bin", "clear-lsp");
}
