import { render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { App } from "./App";

const { diffPreview } = vi.hoisted(() => ({ diffPreview: vi.fn() }));

vi.mock("./monaco/DiffPreview", () => ({
  DiffPreview: diffPreview,
}));

describe("App", () => {
  beforeEach(() => {
    diffPreview.mockClear();
    diffPreview.mockImplementation(() => <div data-testid="diff-preview" />);
  });

  it("presents the revision-aware shell and its typed Monaco preview", () => {
    render(<App />);

    expect(
      screen.getByRole("heading", { name: "Revision-aware diff review" }),
    ).toBeInTheDocument();
    expect(screen.getByTestId("diff-preview")).toBeInTheDocument();
    expect(diffPreview).toHaveBeenCalledWith(
      expect.objectContaining({
        language: "ruby",
        modified: expect.stringContaining("name.strip"),
        original: expect.stringContaining("name\n"),
      }),
      undefined,
    );
  });
});
