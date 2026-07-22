import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { App } from "./App";

const { diffPreview } = vi.hoisted(() => ({ diffPreview: vi.fn() }));
const lines = { code: 1, comments: 0, other: 0 };
const verification = { covered_and_killed: 0, covered: 0, partially_covered: 0, not_covered: 0, unknown: 1 };
const risk = { score: 2, not_covered: 0, partially_covered: 0, added_complexity: 1, tier_one_hazards: 0 };
const findings = [{ source: "scanner", tool: "Scanner", rule_id: "rule", level: "warning", message: "unsafe value", start_line: 1, end_line: 1 }];
const visibility = { public: verification, private: { ...verification, unknown: 0 }, unknown: { ...verification, unknown: 0 } };

vi.mock("./monaco/DiffPreview", () => ({ DiffPreview: diffPreview }));

describe("App", () => {
  beforeEach(() => {
    diffPreview.mockClear();
    diffPreview.mockImplementation(() => <div data-testid="diff-preview" />);
    window.history.replaceState({}, "", "/diff");
  });

  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  it("asks for two immutable revisions when the URL is incomplete", () => {
    render(<App />);
    expect(screen.getByRole("status")).toHaveTextContent("Add immutable base and head revisions");
  });

  it("renders the revision-pinned inventory and only mounts Monaco for two-sided text", async () => {
    window.history.replaceState({}, "", "/diff?base=abc&head=def");
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        api_version: "v1",
        data: {
          scope: { base_oid: "a".repeat(40), head_oid: "b".repeat(40), evidence_scope: { revision: "b".repeat(40), selection: "production", mutant_corpus: "mutants", test_set: "suite" }, policy_version: "diff-risk/v1" },
          inventory: { changed_files: 2, changed_directories: 1, added_files: 1, modified_files: 1, deleted_files: 0, renamed_files: 0, by_role: {}, configuration_paths: [{ path: "Gemfile", kind: "ruby_manifest" }], documentation_paths: ["README.md"], generated_paths: ["generated/app.ts"], lockfile_paths: ["Gemfile.lock"] },
          dependency_changes: [{ manifest_path: "Gemfile", status: "unknown_package_file", entries: [] }, { manifest_path: "Cargo.toml", status: "exact", entries: [{ name: "serde", scope: "runtime", before: null, after: "1" }] }, { manifest_path: "package.json", status: "exact", entries: [] }],
          language_summaries: [{ language: "ruby", production: { code: 1, comments: 0, other: 0 }, test: { code: 0, comments: 0, other: 0 }, production_verification: verification, production_by_visibility: visibility, test_assertions: null }],
          evidence: { coverage: "unknown", mutation: "unknown", hazards: "unknown", sarif: "unknown" },
          files: [
            { path: "lib/app.rb", role: "production", change: "modified", language: "ruby", semantic_classification_available: true, previous_path: null, base_source: "old\nold private", head_source: "new\nnew private", added_lines: lines, removed_lines: { code: 1, comments: 0, other: 0 }, verification, residual_lines: { code: 0, comments: 0, other: 0 }, sarif_findings: findings, risk, groups: [{ name: "run", kind: "function", start_line: 1, end_line: 1, base_start_line: 1, base_end_line: 1, visibility: "public", added_lines: lines, verification, sarif_findings: findings, risk }, { name: "fresh", kind: "function", start_line: 1, end_line: 1, base_start_line: null, base_end_line: null, visibility: "public", added_lines: lines, verification, sarif_findings: [], risk: { ...risk, score: 1 } }, { name: "hide", kind: "function", start_line: 2, end_line: 2, base_start_line: 2, base_end_line: 2, visibility: "private", added_lines: { code: 2, comments: 1, other: 0 }, verification: { ...verification, unknown: 2 }, sarif_findings: [], risk: { ...risk, score: 0, added_complexity: 0 } }, { name: "secret", kind: "function", start_line: 2, end_line: 2, base_start_line: 2, base_end_line: 2, visibility: "private", added_lines: lines, verification, sarif_findings: [], risk: { ...risk, score: 0, added_complexity: 0 } }] },
            { path: "logo.png", role: "other", change: "added", language: null, semantic_classification_available: false, previous_path: null, base_source: null, head_source: null, added_lines: { code: 0, comments: 0, other: 0 }, removed_lines: { code: 0, comments: 0, other: 0 }, verification: { ...verification, unknown: 0 }, residual_lines: { code: 0, comments: 0, other: 0 }, sarif_findings: [], risk: { ...risk, score: 0, added_complexity: 0 }, groups: [] },
          ],
        },
      }),
    }));

    render(<App />);

    expect(await screen.findByText(/2 files in 1 directories/)).toBeInTheDocument();
    expect(screen.getByText(/1 added · 1 modified/)).toBeInTheDocument();
    expect(screen.getByText(/Configuration: Gemfile/)).toBeInTheDocument();
    expect(screen.getByText(/Documentation: README.md/)).toBeInTheDocument();
    expect(screen.getByText(/Generated: generated\/app.ts/)).toBeInTheDocument();
    expect(screen.getByText(/Lockfiles: Gemfile.lock/)).toBeInTheDocument();
    expect(screen.getByText(/unknown package-file change/)).toBeInTheDocument();
    expect(screen.getByText(/serde \(runtime\): not declared → 1/)).toBeInTheDocument();
    expect(screen.getByText(/package.json: no declared dependency changes/)).toBeInTheDocument();
    expect(screen.getByText(/ruby: 1 production code lines.*public 1.*assertions unavailable/)).toBeInTheDocument();
    expect(screen.getByText(/Evidence: coverage unknown/)).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("Base revision"), { target: { value: "next-base" } });
    fireEvent.change(screen.getByLabelText("Head revision"), { target: { value: "next-head" } });
    fireEvent.click(screen.getByRole("button", { name: "Compare revisions" }));
    expect(window.location.search).toContain("base=next-base");
    expect(window.location.search).toContain("head=next-head");
    fireEvent.click(screen.getByRole("button", { name: /lib\/app.rb/ }));
    expect(screen.getByText(/Removals/)).toBeInTheDocument();
    expect(screen.getAllByText(/SARIF findings \(partial\): Scanner\/rule line 1: unsafe value/)).toHaveLength(2);
    expect(screen.getByText(/Private changes \(2 functions/)).toBeInTheDocument();
    expect(diffPreview).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: /function run/ }));
    expect(diffPreview).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByRole("button", { name: /function fresh/ }));
    expect(diffPreview.mock.calls.at(-1)?.[0].original).toBe("");
    fireEvent.click(screen.getByRole("button", { name: /Private changes/ }));
    fireEvent.click(screen.getByRole("button", { name: /function hide/ }));
    expect(diffPreview.mock.calls.at(-1)?.[0].modified).toBe("new private");
    fireEvent.click(screen.getByLabelText("Inline"));
    expect(diffPreview.mock.calls.at(-1)?.[0].sideBySide).toBe(false);
    fireEvent.click(screen.getByRole("button", { name: /Open raw file diff/ }));
    expect(screen.getByText(/Raw diff: lib\/app.rb/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /Back to semantic review/ }));
    expect(screen.getByRole("button", { name: /lib\/app.rb/ })).toBeInTheDocument();
  });

  it("makes failed diff requests visible", async () => {
    window.history.replaceState({}, "", "/diff?base=abc&head=def");
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: false, status: 500 }));
    render(<App />);
    expect(await screen.findByRole("alert")).toHaveTextContent("Diff plan request failed (500)");
  });
});
