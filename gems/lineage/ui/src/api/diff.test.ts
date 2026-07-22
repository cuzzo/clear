import { describe, expect, it, vi } from "vitest";
import { DiffApiError, fetchDiffPlan, revisionsFromSearch } from "./diff";

const plan = { scope: {}, inventory: {}, dependency_changes: [], files: [] };

describe("diff API", () => {
  it("reads only complete revision pairs from the URL", () => {
    expect(revisionsFromSearch("?base=abc&head=def")).toEqual({ base: "abc", head: "def" });
    expect(revisionsFromSearch("?base=abc")).toBeNull();
    expect(revisionsFromSearch("?base=%20&head=def")).toBeNull();
  });

  it("requests and validates a versioned diff plan", async () => {
    const fetcher = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ api_version: "v1", data: plan }) });
    await expect(fetchDiffPlan({ base: "abc", head: "def" }, fetcher)).resolves.toBe(plan);
    expect(fetcher).toHaveBeenCalledWith("/api/diff/plan?base=abc&head=def");
  });

  it("rejects failed, incompatible, and incomplete responses", async () => {
    await expect(fetchDiffPlan({ base: "a", head: "b" }, vi.fn().mockResolvedValue({ ok: false, status: 500 }))).rejects.toBeInstanceOf(DiffApiError);
    await expect(fetchDiffPlan({ base: "a", head: "b" }, vi.fn().mockResolvedValue({ ok: true, json: async () => ({ api_version: "v2", data: plan }) }))).rejects.toBeInstanceOf(DiffApiError);
    await expect(fetchDiffPlan({ base: "a", head: "b" }, vi.fn().mockResolvedValue({ ok: true, json: async () => ({ api_version: "v1", data: {} }) }))).rejects.toBeInstanceOf(DiffApiError);
  });
});
