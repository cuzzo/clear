import { beforeEach, describe, expect, it, vi } from "vitest";
import { mountApplication } from "./bootstrap";

const { createRoot } = vi.hoisted(() => ({ createRoot: vi.fn() }));
const render = vi.fn();

vi.mock("react-dom/client", () => ({ createRoot }));

describe("mountApplication", () => {
  beforeEach(() => {
    createRoot.mockClear();
    createRoot.mockReturnValue({ render });
    render.mockClear();
  });

  it("mounts the React application in an HTML root", () => {
    const root = document.createElement("div");

    mountApplication(root);

    expect(createRoot).toHaveBeenCalledWith(root);
    expect(render).toHaveBeenCalledTimes(1);
  });

  it("rejects missing and non-HTML roots", () => {
    expect(() => mountApplication(null)).toThrow("requires an HTML root element");
    expect(() => mountApplication(document.createElementNS("http://www.w3.org/2000/svg", "svg"))).toThrow(
      "requires an HTML root element",
    );
  });
});
