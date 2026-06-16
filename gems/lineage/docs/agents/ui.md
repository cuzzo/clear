# Lineage UI: Local-First Observability Portal

This document outlines the design for the `Lineage UI`, a lightweight, local-first web interface for visualizing historical risk, verification gaps, and logical-unit lineage. The UI is served directly from the `lineage` Rust binary.

## 1. Product Philosophy: "High-Alpha Safety"

The goal of the UI is to transform the "Ground Truth" stored in the `lineage.db` into a visceral, actionable experience for developers and LLMs. It moves risk from a JSON log to a visual "Heatmap" embedded directly in the source code context.

## 2. Architecture: Single-Binary Delivery

To ensure zero-config installation and high performance, the UI follows a "Local-First" architecture.

- **Backend (Rust/Axum):** A high-performance web server embedded in the `lineage` crate. It provides JSON endpoints for file navigation and risk-querying.
- **Frontend (React/Monaco):** A modern, high-density dashboard. The core view uses the **Monaco Editor** (VS Code engine) to render source code with custom gutter decorations.
- **Asset Embedding:** The compiled React frontend is embedded into the Rust binary using `rust-embed`, allowing the entire portal to be served via `lineage ui --port 8080`.

## 3. Core Features

### A. The "Risk Gutter" (Virtual Gutter)
Using Monaco’s `deltaDecorations` API, the UI injects icons and color-coding directly into the gutter:
- **Red Bolt:** Unverified Atomic Hazard (Missing Loom coverage).
- **Yellow Shield:** Churned logic with low mutant-kill rate.
- **Green Check:** Verified, load-bearing logic.
- **Crash Icon:** Line anchored to a production Sentry stack trace.

### B. Temporal Diff-Explorer
A side-by-side diff view that tracks a **Logical Unit ID** instead of a file path. It allows developers to see how a specific function has evolved across renames and moves, with commit metadata (bugfix tags) highlighted.

### C. Verification Heatmap
A repository-wide treemap visualizing the "Integrity Gap":
- X-Axis: Structural Complexity (Decomplex).
- Y-Axis: Historical Churn (Boobytrap).
- Color: Verification Status (TSan/Loom/ASan/Mutant coverage).

## 4. Why Rust over Rails/Go?

| Metric | Rust (Axum) | Rails/Python | Go |
| :--- | :--- | :--- | :--- |
| **Distribution** | Single 10MB Binary | Complex (Dep management) | Single Binary |
| **Memory** | < 10MB RAM | > 100MB RAM | < 20MB RAM |
| **Logic Sharing** | Native (Zero FFI) | Heavy FFI / Subprocess | CGO / Subprocess |
| **Product Brand**| High-end Systems Tool | Scripting Utility | Infrastructure Tool |

**Verdict:** Rust is the only path that maintains the "Systems Integrity" brand and allows for easy future migration to a standalone **Tauri** desktop application.

## 5. Implementation Roadmap

- **Phase 1: API (150 LoC):** Implement Axum routes for `/files`, `/source/:path`, and `/lineage/:path`.
- **Phase 2: Monaco Wrapper (300 LoC):** Build the React component for the code view with decoration support.
- **Phase 3: Integration (100 LoC):** Join `lineage.db` queries to the API and embed assets.

## 6. Strategic Narrative

The Lineage UI is the "Front Window" of the suite. It is the tool you show on the v0.1 launch landing page to prove that your "Deep History" and "Systems Integrity" claims are not just theoretical—they are visible, navigable, and ready for the real world.
