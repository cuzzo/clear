import { describe, expect, it, vi } from "vitest";
import { DiffApiError, fetchDiffPlan, revisionsFromSearch } from "./diff";

const slices = { covered_and_killed: 0, covered: 0, partially_covered: 0, not_covered: 0, unknown: 0 };
const plan = {
  scope: { base_oid: "a".repeat(40), head_oid: "b".repeat(40), evidence_scope: { revision: "b".repeat(40), selection: "production", mutant_corpus: "mutants", test_set: "suite" }, policy_version: "diff-risk/v1" },
  inventory: { changed_directories: 1, changed_files: 1, added_files: 0, modified_files: 1, deleted_files: 0, renamed_files: 0, by_role: {}, configuration_paths: [], documentation_paths: [], generated_paths: [], lockfile_paths: [] },
  dependency_changes: [{ manifest_path: "Cargo.toml", status: "exact", entries: [{ name: "serde", scope: "runtime", before: null, after: "1" }] }],
  language_summaries: [],
  evidence: { coverage: "missing", mutation: "missing", hazards: "missing", sarif: "missing" },
  files: [{ path: "lib/example.rb", previous_path: null, change: "modified", role: "production", language: "ruby", semantic_classification_available: true, base_source: "old", head_source: "new", added_lines: { code: 1, comments: 0, other: 0 }, removed_lines: { code: 1, comments: 0, other: 0 }, verification: slices, line_annotations: [{ line: 1, verification: "covered" }], residual_lines: { code: 1, comments: 0, other: 0 }, groups: [], sarif_findings: [], risk: { score: 0, not_covered: 0, partially_covered: 0, added_complexity: 0, tier_one_hazards: 0 } }],
};

describe("diff API", () => {
  it("reads only complete revision pairs from the URL", () => {
    expect(revisionsFromSearch("?base=abc&head=def")).toEqual({ base: "abc", head: "def", coverage_source: undefined, sarif_source: undefined, selection: undefined, mutant_corpus: undefined, test_set: undefined });
    expect(revisionsFromSearch("?base=abc&head=def&coverage_source=coverage%3Aci&sarif_source=scanner&selection=production&mutant_corpus=mutants&test_set=suite")).toEqual({ base: "abc", head: "def", coverage_source: "coverage:ci", sarif_source: "scanner", selection: "production", mutant_corpus: "mutants", test_set: "suite" });
    expect(revisionsFromSearch("?base=abc")).toBeNull();
    expect(revisionsFromSearch("?base=%20&head=def")).toBeNull();
  });

  it("requests and validates a versioned diff plan", async () => {
    const fetcher = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ api_version: "v1", data: plan }) });
    await expect(fetchDiffPlan({ base: "abc", head: "def" }, fetcher)).resolves.toBe(plan);
    expect(fetcher).toHaveBeenCalledWith("/api/diff/plan?base=abc&head=def");
    await fetchDiffPlan({ base: "abc", head: "def", coverage_source: "coverage:ci", sarif_source: "scanner", selection: "production", mutant_corpus: "mutants", test_set: "suite" }, fetcher);
    expect(fetcher).toHaveBeenLastCalledWith("/api/diff/plan?base=abc&head=def&coverage_source=coverage%3Aci&sarif_source=scanner&selection=production&mutant_corpus=mutants&test_set=suite");
  });

  it("rejects failed, incompatible, and incomplete responses", async () => {
    await expect(fetchDiffPlan({ base: "a", head: "b" }, vi.fn().mockResolvedValue({ ok: false, status: 500 }))).rejects.toBeInstanceOf(DiffApiError);
    await expect(fetchDiffPlan({ base: "a", head: "b" }, vi.fn().mockResolvedValue({ ok: true, json: async () => ({ api_version: "v2", data: plan }) }))).rejects.toBeInstanceOf(DiffApiError);
    await expect(fetchDiffPlan({ base: "a", head: "b" }, vi.fn().mockResolvedValue({ ok: true, json: async () => ({ api_version: "v1", data: {} }) }))).rejects.toBeInstanceOf(DiffApiError);
    await expect(fetchDiffPlan({ base: "a", head: "b" }, vi.fn().mockResolvedValue({ ok: true, json: async () => ({ api_version: "v1", data: { ...plan, files: [{ ...plan.files[0], risk: { score: "unsafe" } }] } }) }))).rejects.toBeInstanceOf(DiffApiError);
  });
});
