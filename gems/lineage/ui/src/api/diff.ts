export type { AddedLines, DependencyChange, DiffFile, DiffGroup, DiffPlan, LineAnnotation, RiskSummary, VerificationSlices } from "../generated/diff";
import type { DiffPlan } from "../generated/diff";

export class DiffApiError extends Error {}

export interface DiffRequest {
  readonly base: string;
  readonly head: string;
  readonly coverage_source?: string;
  readonly sarif_source?: string;
  readonly selection?: string;
  readonly mutant_corpus?: string;
  readonly test_set?: string;
}

export function revisionsFromSearch(search: string): DiffRequest | null {
  const query = new URLSearchParams(search);
  const base = query.get("base")?.trim();
  const head = query.get("head")?.trim();
  if (!base || !head) return null;
  const optional = (name: string): string | undefined => query.get(name)?.trim() || undefined;
  return {
    base,
    head,
    coverage_source: optional("coverage_source"),
    sarif_source: optional("sarif_source"),
    selection: optional("selection"),
    mutant_corpus: optional("mutant_corpus"),
    test_set: optional("test_set"),
  };
}

export async function fetchDiffPlan(
  revisions: DiffRequest,
  fetcher: typeof fetch = fetch,
): Promise<DiffPlan> {
  const query = new URLSearchParams();
  for (const [name, value] of Object.entries(revisions)) {
    if (value) query.set(name, value);
  }
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
  if (!isDiffPlan(data)) {
    throw new DiffApiError("Diff API response is missing required plan fields");
  }
  return data;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isDiffPlan(value: Record<string, unknown>): value is DiffPlan {
  return isScope(value.scope)
    && isInventory(value.inventory)
    && isEvidence(value.evidence)
    && isArrayOf(value.dependency_changes, isDependencyChange)
    && isArrayOf(value.language_summaries, isLanguageSummary)
    && isArrayOf(value.files, isDiffFile);
}

function isScope(value: unknown): boolean {
  return hasStrings(value, ["base_oid", "head_oid", "policy_version"])
    && isRecord(value)
    && hasStrings(value.evidence_scope, ["revision", "selection", "mutant_corpus", "test_set"]);
}

function isInventory(value: unknown): boolean {
  return hasNumbers(value, ["changed_directories", "changed_files", "added_files", "modified_files", "deleted_files", "renamed_files"])
    && isRecord(value)
    && isRecord(value.by_role)
    && isArrayOf(value.configuration_paths, (entry) => hasStrings(entry, ["path", "kind"]))
    && isArrayOf(value.documentation_paths, isString)
    && isArrayOf(value.generated_paths, isString)
    && isArrayOf(value.lockfile_paths, isString);
}

function isEvidence(value: unknown): boolean {
  return hasEnumFields(value, ["coverage", "mutation", "hazards", "sarif"], evidenceStates);
}

function isDependencyChange(value: unknown): boolean {
  return hasStrings(value, ["manifest_path"])
    && hasEnumFields(value, ["status"], dependencyStatuses)
    && isRecord(value)
    && isArrayOf(value.entries, isDependencyEntry);
}

function isLanguageSummary(value: unknown): boolean {
  return hasStrings(value, ["language"])
    && isRecord(value)
    && isAddedLines(value.production)
    && isAddedLines(value.test)
    && isVerification(value.production_verification)
    && isVisibilityVerification(value.production_by_visibility)
    && (typeof value.test_assertions === "number" || value.test_assertions === null);
}

function isDiffFile(value: unknown): boolean {
  return hasStrings(value, ["path"])
    && hasEnumFields(value, ["change"], fileChangeKinds)
    && hasEnumFields(value, ["role"], sourceRoles)
    && isRecord(value)
    && nullableString(value.previous_path)
    && nullableString(value.language)
    && typeof value.semantic_classification_available === "boolean"
    && nullableString(value.base_source)
    && nullableString(value.head_source)
    && isAddedLines(value.added_lines)
    && isAddedLines(value.removed_lines)
    && isVerification(value.verification)
    && isArrayOf(value.line_annotations, isLineAnnotation)
    && isAddedLines(value.residual_lines)
    && isRisk(value.risk)
    && isArrayOf(value.groups, isDiffGroup)
    && isArrayOf(value.sarif_findings, isFinding);
}

function isLineAnnotation(value: unknown): boolean {
  return isRecord(value) && typeof value.line === "number" && lineVerifications.includes(value.verification as never);
}

function isDiffGroup(value: unknown): boolean {
  return hasStrings(value, ["name", "kind"])
    && hasNumbers(value, ["start_line", "end_line"])
    && hasEnumFields(value, ["visibility"], visibilities)
    && isRecord(value)
    && nullableNumber(value.base_start_line)
    && nullableNumber(value.base_end_line)
    && isAddedLines(value.added_lines)
    && isVerification(value.verification)
    && isRisk(value.risk)
    && isArrayOf(value.sarif_findings, isFinding);
}

function isFinding(value: unknown): boolean {
  return hasStrings(value, ["source", "tool", "rule_id", "level", "message", "fingerprint", "status"])
    && isRecord(value)
    && typeof value.tier_one === "boolean"
    && hasNumbers(value, ["start_line", "end_line"]);
}

function isDependencyEntry(value: unknown): boolean {
  return isRecord(value)
    && hasStrings(value, ["name", "scope"])
    && nullableString(value.before)
    && nullableString(value.after);
}

function isAddedLines(value: unknown): boolean { return hasNumbers(value, ["code", "comments", "other"]); }
function isVerification(value: unknown): boolean { return hasNumbers(value, ["covered_and_killed", "covered", "partially_covered", "not_covered", "unknown"]); }
function isRisk(value: unknown): boolean { return hasNumbers(value, ["score", "not_covered", "partially_covered", "added_complexity", "tier_one_hazards"]); }
function isVisibilityVerification(value: unknown): boolean {
  return isRecord(value) && isVerification(value.public) && isVerification(value.private) && isVerification(value.unknown);
}

function hasStrings(value: unknown, fields: readonly string[]): boolean { return isRecord(value) && fields.every((field) => typeof value[field] === "string"); }
function hasNumbers(value: unknown, fields: readonly string[]): boolean { return isRecord(value) && fields.every((field) => typeof value[field] === "number" && Number.isFinite(value[field])); }
function hasEnumFields(value: unknown, fields: readonly string[], allowed: readonly string[]): boolean { return isRecord(value) && fields.every((field) => typeof value[field] === "string" && allowed.includes(value[field])); }
function isArrayOf(value: unknown, predicate: (entry: unknown) => boolean): boolean { return Array.isArray(value) && value.every(predicate); }
function isString(value: unknown): boolean { return typeof value === "string"; }
function nullableString(value: unknown): boolean { return typeof value === "string" || value === null; }
function nullableNumber(value: unknown): boolean { return typeof value === "number" || value === null; }

const evidenceStates = ["exact", "stale", "missing", "partial", "unknown"] as const;
const dependencyStatuses = ["exact", "unknown_package_file"] as const;
const fileChangeKinds = ["added", "modified", "deleted", "renamed"] as const;
const sourceRoles = ["production", "test", "documentation", "configuration", "generated", "lockfile", "other"] as const;
const visibilities = ["public", "private", "unknown"] as const;
const lineVerifications = ["covered_and_killed", "covered", "partially_covered", "not_covered", "unknown"] as const;
