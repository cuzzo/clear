import { render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { DiffPreview, modifiedDecorations } from "./DiffPreview";

const { diffEditor } = vi.hoisted(() => ({ diffEditor: vi.fn() }));

vi.mock("@monaco-editor/react", () => ({
  DiffEditor: diffEditor,
}));

describe("DiffPreview", () => {
  beforeEach(() => {
    diffEditor.mockClear();
    diffEditor.mockImplementation(() => <div data-testid="monaco-diff" />);
  });

  it("configures a read-only side-by-side Monaco diff", () => {
    render(<DiffPreview language="ruby" modified="new" original="old" />);

    expect(screen.getByTestId("monaco-diff")).toBeInTheDocument();
    expect(diffEditor).toHaveBeenCalledWith(
      expect.objectContaining({
        height: "18rem",
        language: "ruby",
        modified: "new",
        original: "old",
        theme: "vs-dark",
      }),
      undefined,
    );
    expect(diffEditor.mock.calls[0]?.[0].options).toEqual({
      automaticLayout: true,
      minimap: { enabled: false },
      readOnly: true,
      renderSideBySide: true,
    });
  });

  it("passes the requested inline layout through to Monaco", () => {
    render(<DiffPreview language="ruby" modified="new" original="old" sideBySide={false} />);

    expect(diffEditor.mock.calls[0]?.[0].options.renderSideBySide).toBe(false);
  });

  it("marks SARIF source spans on Monaco's modified side", () => {
    const Range = vi.fn(function(this: { args: unknown[] }, ...args: unknown[]) { this.args = args; });
    const monaco = { Range, editor: { OverviewRulerLane: { Right: 7 } } } as never;
    const decorations = modifiedDecorations([{ startLine: 2, endLine: 4, title: "Scanner/rule: unsafe" }], monaco);

    expect(Range).toHaveBeenCalledWith(2, 1, 4, 1);
    expect(decorations[0]?.options).toMatchObject({ className: "lineage-sarif-line", isWholeLine: true });
  });

  it("applies highlights when the Monaco diff editor mounts", () => {
    render(<DiffPreview highlights={[{ startLine: 1, endLine: 1, title: "finding" }]} language="ruby" modified="new" original="old" />);
    const createDecorationsCollection = vi.fn();
    const onMount = diffEditor.mock.calls[0]?.[0].onMount;
    onMount({ getModifiedEditor: () => ({ createDecorationsCollection }) }, {
      Range: class { constructor(..._args: unknown[]) {} },
      editor: { OverviewRulerLane: { Right: 7 } },
    });

    expect(createDecorationsCollection).toHaveBeenCalledTimes(1);
  });
});
