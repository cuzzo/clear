import { afterEach, describe, expect, it, vi } from "vitest";

const mountApplication = vi.fn();

vi.mock("./bootstrap", () => ({ mountApplication }));

describe("main", () => {
  afterEach(() => {
    document.body.replaceChildren();
    mountApplication.mockClear();
  });

  it("mounts into the document root", async () => {
    const root = document.createElement("div");
    root.id = "root";
    document.body.append(root);

    await import("./main");

    expect(mountApplication).toHaveBeenCalledWith(root);
  });
});
