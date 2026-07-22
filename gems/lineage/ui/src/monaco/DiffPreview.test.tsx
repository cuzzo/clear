import { render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { DiffPreview } from "./DiffPreview";

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
});
