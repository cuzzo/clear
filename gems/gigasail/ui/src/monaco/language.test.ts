import { describe, expect, it } from "vitest";
import { languageForPath } from "./language";

describe("languageForPath", () => {
  it("maps supported implementation and configuration extensions", () => {
    expect(languageForPath("lib/example.rb")).toBe("ruby");
    expect(languageForPath("ui/component.tsx")).toBe("typescript");
    expect(languageForPath(".github/workflows/ci.yml")).toBe("yaml");
    expect(languageForPath("engine/main.zig")).toBe("zig");
  });

  it("uses plaintext for extensionless and unsupported paths", () => {
    expect(languageForPath("Dockerfile")).toBe("plaintext");
    expect(languageForPath("assets/image.avif")).toBe("plaintext");
  });
});
