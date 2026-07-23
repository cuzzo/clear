# Gigasail LSP: Real-Time Risk Context in the Editor

This document outlines the design for the `Gigasail` Language Server Protocol (LSP) implementation. The goal is to surface deep historical and operational risk (churn, bugs, missing sanitizer coverage) directly in the developer’s editor via gutters, hovers, and diagnostics.

## 1. The Strategy: "Write with History"

To be effective, risk awareness cannot be relegated to a CI step or a separate dashboard. It must be visible at the moment the code is being changed. By implementing an LSP, `Gigasail` becomes a continuous background "Safety Copilot" for VS Code, Neovim, Emacs, and IntelliJ.

## 2. LSP Feature Implementation

The `gigasail` Rust crate will implement a fast, non-blocking LSP using the `tower-lsp` ecosystem.

### A. Diagnostics (`textDocument/publishDiagnostics`)
- **What:** Surfaces "Integrity Gaps" (e.g., Unverified Atomics from `SlopCop`, High-Risk Churn from `Boobytrap`).
- **Display:** Standard editor squiggles and problems panel warnings.
- **Value:** The developer is instantly notified if they are editing a function that lacks required Systems Coverage.

### B. Hover Information (`textDocument/hover`)
- **What:** Provides the temporal metadata for the current Logical Unit.
- **Display:** When the user hovers over a function definition, they see:
  - Risk Profile (e.g., *Hardened Veteran* vs. *Lurking Disaster*).
  - Recent Bugfixes (Last 3 commits that fixed this unit).
  - Production Crash Summary (e.g., *3 Sentry events on this line*).

### C. CodeLens (`textDocument/codeLens`)
- **What:** Inline, non-intrusive metadata above function declarations.
- **Display:** `[ Risk: 8.5 | 4 Bugfixes | 100% Mutant Kill Rate ]`
- **Value:** Immediate context without requiring a hover action.

## 3. The "Visual Gutter" Challenge (Non-Standard Extensions)

The LSP specification does not yet natively support injecting visual icons into the line-number gutter. To achieve the "Red Bolt" (Unverified Atomic) or "Green Shield" (Hard-Gated) experience:

- **VS Code Extension (TypeScript Wrapper):** We will provide a thin extension that launches the Rust binary and listens for custom LSP notifications (`gigasail/gutterUpdate`). It uses VS Code’s `DecorationOptions` API to draw the glyphs.
- **Neovim (Lua Wrapper):** A simple Lua plugin that maps the same custom notifications to Neovim `signs` in the sign column.

## 4. Architecture: The Universal Agent

The `gigasail` binary will support three execution modes to ensure maximum code reuse:
1. `giga build` / `giga ingest` (CLI data pipelines).
2. `giga ui` (Local Axum-based web dashboard).
3. `giga lsp` (Background process communicating via `stdio`).

## 5. Implementation Roadmap

- **Phase 1: LSP Scaffold.** Implement `tower-lsp` and bind to the `Storage` SQLite queries.
- **Phase 2: Standard Features.** Implement Hover and Diagnostics using existing `LogicalUnit` facts.
- **Phase 3: CodeLens.** Surface aggregate risk scores above functions.
- **Phase 4: Editor Wrappers.** Build the VS Code and Neovim plugins to render the custom `gigasail/gutterUpdate` messages.

## 6. MVP Implementation Status

The Rust crate now exposes `giga lsp --repo . --db gigasail.db` as a stdio LSP server. It deliberately reuses the same Gigasail annotation query path as the HTML UI so editor gutters and the browser view do not drift.

Implemented:
- `textDocument/publishDiagnostics` for uncovered dark arms and open systems hazards.
- `textDocument/hover` with logical-unit risk, bugfix/change counts, test evidence, line hits, hazards, and dark-arm details.
- `textDocument/codeLens` with unit-level risk/test summaries above tracked units.
- Custom `gigasail/gutterUpdate` notifications containing covered-line, mutant-tested, hazard, and dark-arm gutter items.

Not yet implemented:
- VS Code extension wrapper that maps `gigasail/gutterUpdate` to `DecorationOptions`.
- Neovim Lua wrapper that maps `gigasail/gutterUpdate` to signs/extmarks.
- Pull diagnostics via `textDocument/diagnostic`; the MVP publishes diagnostics on open/change/save because that works broadly across current clients.

## 7. Strategic Impact

The LSP bridges the gap between the "Architect" (who reads the markdown reports) and the "Developer" (who is writing the code). By embedding the `Gigasail` signal directly into the editor, the toolchain becomes a daily dependency that actively prevents regressions before they are committed.
