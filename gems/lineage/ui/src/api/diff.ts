export type ChangeKind = "added" | "modified" | "deleted" | "renamed";
export type SourceRole = "production" | "test" | "documentation" | "configuration" | "generated" | "lockfile" | "other";

export interface DiffFile {
  readonly path: string;
  readonly previous_path: string | null;
  readonly change: ChangeKind;
  readonly role: SourceRole;
  readonly language: string | null;
  readonly base_source: string | null;
  readonly head_source: string | null;
  readonly added_lines: AddedLines;
  readonly groups: readonly DiffGroup[];
  readonly risk: { readonly score: number; readonly added_complexity: number; readonly tier_one_hazards: number };
}

export interface AddedLines { readonly code: number; readonly comments: number; readonly other: number }

export interface DiffGroup {
  readonly name: string;
  readonly kind: string;
  readonly start_line: number;
  readonly end_line: number;
  readonly visibility: "public" | "private" | "unknown";
  readonly added_lines: AddedLines;
}

export interface DiffPlan {
  readonly scope: { readonly base_oid: string; readonly head_oid: string; readonly policy_version: string };
  readonly inventory: { readonly changed_directories: number; readonly changed_files: number; readonly by_role: Readonly<Record<string, number>> };
  readonly dependency_changes: readonly { readonly manifest_path: string; readonly status: "exact" | "unknown_package_file" }[];
  readonly language_summaries: readonly { readonly language: string; readonly production: AddedLines; readonly test: AddedLines }[];
  readonly evidence: { readonly coverage: "unknown"; readonly mutation: "unknown"; readonly hazards: "unknown"; readonly sarif: "unknown" };
  readonly files: readonly DiffFile[];
}

export class DiffApiError extends Error {}

export function revisionsFromSearch(search: string): { base: string; head: string } | null {
  const query = new URLSearchParams(search);
  const base = query.get("base")?.trim();
  const head = query.get("head")?.trim();
  return base && head ? { base, head } : null;
}

export async function fetchDiffPlan(
  revisions: { readonly base: string; readonly head: string },
  fetcher: typeof fetch = fetch,
): Promise<DiffPlan> {
  const query = new URLSearchParams(revisions);
  const response = await fetcher(`/api/diff/plan?${query}`);
  if (!response.ok) throw new DiffApiError(`Diff plan request failed (${response.status})`);
  const envelope: unknown = await response.json();
  return parseEnvelope(envelope);
}

function parseEnvelope(value: unknown): DiffPlan {
  if (!isRecord(value) || value.api_version !== "v1" || !isRecord(value.data)) {
    throw new DiffApiError("Diff API returned an incompatible response");
  }
  const { data } = value;
  if (!isRecord(data.scope) || !isRecord(data.inventory) || !Array.isArray(data.files) || !Array.isArray(data.dependency_changes)) {
    throw new DiffApiError("Diff API response is missing required plan fields");
  }
  return data as unknown as DiffPlan;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
