import { render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { App } from "./App";

const { diffPreview } = vi.hoisted(() => ({ diffPreview: vi.fn() }));

vi.mock("./monaco/DiffPreview", () => ({ DiffPreview: diffPreview }));

describe("App", () => {
  beforeEach(() => {
    diffPreview.mockClear();
    diffPreview.mockImplementation(() => <div data-testid="diff-preview" />);
    window.history.replaceState({}, "", "/diff");
  });

  afterEach(() => vi.unstubAllGlobals());

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
          scope: { base_oid: "a".repeat(40), head_oid: "b".repeat(40), policy_version: "diff-risk/v1" },
          inventory: { changed_files: 2, changed_directories: 1, by_role: {} },
          dependency_changes: [{ manifest_path: "Gemfile", status: "unknown_package_file" }],
          files: [
            { path: "lib/app.rb", role: "production", change: "modified", language: "ruby", previous_path: null, base_source: "old", head_source: "new" },
            { path: "logo.png", role: "other", change: "added", language: null, previous_path: null, base_source: null, head_source: null },
          ],
        },
      }),
    }));

    render(<App />);

    expect(await screen.findByText(/2 files in 1 directories/)).toBeInTheDocument();
    expect(screen.getByText(/unknown package-file change/)).toBeInTheDocument();
    expect(screen.getByText(/Binary or one-sided change/)).toBeInTheDocument();
    expect(diffPreview).toHaveBeenCalledTimes(1);
  });

  it("makes failed diff requests visible", async () => {
    window.history.replaceState({}, "", "/diff?base=abc&head=def");
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: false, status: 500 }));
    render(<App />);
    expect(await screen.findByRole("alert")).toHaveTextContent("Diff plan request failed (500)");
  });
});
