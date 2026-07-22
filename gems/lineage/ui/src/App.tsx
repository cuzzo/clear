import { useEffect, useState } from "react";
import { DiffApiError, type AddedLines, type DependencyChange, type DiffFile, type DiffGroup, type DiffPlan, type RiskSummary, type VerificationSlices, fetchDiffPlan, revisionsFromSearch } from "./api/diff";
import { DiffPreview, type SourceHighlight } from "./monaco/DiffPreview";

export function App(): React.JSX.Element {
  const [location, setLocation] = useState(window.location.search);
  const revisions = revisionsFromSearch(location);
  const query = new URLSearchParams(location);
  const requestedLayout = query.get("layout");
  const initialLayout = requestedLayout === "inline" || requestedLayout === "split"
    ? requestedLayout
    : window.localStorage.getItem("lineage.diff.layout") === "inline" || window.innerWidth < 900
      ? "inline"
      : "split";
  const [plan, setPlan] = useState<DiffPlan | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!revisions) return;
    void fetchDiffPlan(revisions).then(setPlan).catch((reason: unknown) => {
      setError(reason instanceof DiffApiError ? reason.message : "Unable to load diff plan");
    });
  }, [revisions?.base, revisions?.head]);

  useEffect(() => {
    const updateLocation = () => setLocation(window.location.search);
    window.addEventListener("popstate", updateLocation);
    return () => window.removeEventListener("popstate", updateLocation);
  }, []);

  return (
    <main className="app-shell">
      <header>
        <p className="eyebrow">Lineage</p>
        <h1>Revision-aware diff review</h1>
        <p>Revision-pinned inventory and raw source review.</p>
      </header>
      <RevisionControls revisions={revisions} />
      {!revisions && <p role="status">Add immutable base and head revisions to the URL to begin review.</p>}
      {error && <p role="alert">{error}</p>}
      {plan && <DiffReview initialLayout={initialLayout} plan={plan} rawPath={query.get("presentation") === "raw" ? query.get("path") : null} />}
    </main>
  );
}

function DiffReview({ initialLayout, plan, rawPath }: { readonly initialLayout: "inline" | "split"; readonly plan: DiffPlan; readonly rawPath: string | null }): React.JSX.Element {
  const [sideBySide, setSideBySide] = useState(() => initialLayout === "split");
  const rawFile = rawPath ? plan.files.find((file) => file.path === rawPath) : undefined;
  useEffect(() => setSideBySide(initialLayout === "split"), [initialLayout]);
  const setLayout = (next: boolean) => {
    const nextQuery = new URLSearchParams(window.location.search);
    nextQuery.set("layout", next ? "split" : "inline");
    window.history.replaceState({}, "", `${window.location.pathname}?${nextQuery}`);
    window.localStorage.setItem("lineage.diff.layout", next ? "split" : "inline");
    setSideBySide(next);
  };
  const openRaw = (path: string) => {
    const nextQuery = new URLSearchParams(window.location.search);
    nextQuery.set("presentation", "raw");
    nextQuery.set("path", path);
    nextQuery.set("focus", "residual");
    window.history.replaceState({}, "", `${window.location.pathname}?${nextQuery}`);
    window.dispatchEvent(new PopStateEvent("popstate"));
  };
  const closeRaw = () => {
    const nextQuery = new URLSearchParams(window.location.search);
    nextQuery.delete("presentation");
    nextQuery.delete("path");
    nextQuery.delete("focus");
    window.history.replaceState({}, "", `${window.location.pathname}?${nextQuery}`);
    window.dispatchEvent(new PopStateEvent("popstate"));
  };
  return <section aria-label="Diff inventory" className="preview-card">
    <p>{plan.inventory.changed_files} files in {plan.inventory.changed_directories} directories</p>
    <p>{plan.inventory.added_files} added · {plan.inventory.modified_files} modified · {plan.inventory.deleted_files} deleted · {plan.inventory.renamed_files} renamed</p>
    <p>Base {plan.scope.base_oid} · Head {plan.scope.head_oid}</p>
    <p>Evidence scope: {plan.scope.evidence_scope.selection} · {plan.scope.evidence_scope.mutant_corpus} · {plan.scope.evidence_scope.test_set}</p>
    <p>Evidence: coverage {plan.evidence.coverage} · mutation {plan.evidence.mutation} · hazards {plan.evidence.hazards} · SARIF {plan.evidence.sarif}</p>
    <InventoryPaths label="Configuration" paths={plan.inventory.configuration_paths.map((file) => `${file.path} (${file.kind})`)} />
    <InventoryPaths label="Documentation" paths={plan.inventory.documentation_paths} />
    <InventoryPaths label="Generated" paths={plan.inventory.generated_paths} />
    <InventoryPaths label="Lockfiles" paths={plan.inventory.lockfile_paths} />
    {plan.dependency_changes.map((change) => <DependencySummary change={change} key={change.manifest_path} />)}
    {plan.language_summaries.map((summary) => <LanguageSummaryCard key={summary.language} summary={summary} />)}
    <fieldset><legend>Diff layout</legend><label><input checked={sideBySide} name="layout" onChange={() => setLayout(true)} type="radio" />Side by side</label><label><input checked={!sideBySide} name="layout" onChange={() => setLayout(false)} type="radio" />Inline</label></fieldset>
    {rawFile ? <RawReview file={rawFile} onBack={closeRaw} sideBySide={sideBySide} /> : plan.files.map((file) => <FileReview file={file} key={file.path} onRaw={openRaw} sideBySide={sideBySide} />)}
  </section>;
}

function RevisionControls({ revisions }: { readonly revisions: { readonly base: string; readonly head: string } | null }): React.JSX.Element {
  const [base, setBase] = useState(revisions?.base ?? "");
  const [head, setHead] = useState(revisions?.head ?? "");
  useEffect(() => {
    setBase(revisions?.base ?? "");
    setHead(revisions?.head ?? "");
  }, [revisions?.base, revisions?.head]);
  const chooseRevisions = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!base.trim() || !head.trim()) return;
    const next = new URLSearchParams(window.location.search);
    next.set("base", base.trim());
    next.set("head", head.trim());
    next.delete("presentation");
    next.delete("path");
    window.history.pushState({}, "", `${window.location.pathname}?${next}`);
    window.dispatchEvent(new PopStateEvent("popstate"));
  };
  return <form aria-label="Revision comparison" className="revision-controls" onSubmit={chooseRevisions}>
    <label>Base revision <input aria-label="Base revision" onChange={(event) => setBase(event.target.value)} required value={base} /></label>
    <label>Head revision <input aria-label="Head revision" onChange={(event) => setHead(event.target.value)} required value={head} /></label>
    <button type="submit">Compare revisions</button>
  </form>;
}

function DependencySummary({ change }: { readonly change: DependencyChange }): React.JSX.Element {
  if (change.status !== "exact") return <p>{change.manifest_path}: unknown package-file change</p>;
  if (change.entries.length === 0) return <p>{change.manifest_path}: no declared dependency changes</p>;
  return <section aria-label={`Dependency changes for ${change.manifest_path}`}><p>{change.manifest_path}: declared dependency changes</p><ul>{change.entries.map((entry) => <li key={`${entry.scope}:${entry.name}`}>{entry.name} ({entry.scope}): {entry.before ?? "not declared"} → {entry.after ?? "not declared"}</li>)}</ul></section>;
}

function LanguageSummaryCard({ summary }: { readonly summary: DiffPlan["language_summaries"][number] }): React.JSX.Element {
  const visibility = summary.production_by_visibility;
  return <p>{summary.language}: {summary.production.code} production code lines · public {verificationTotal(visibility.public)} · private {verificationTotal(visibility.private)} · unknown visibility {verificationTotal(visibility.unknown)} · <VerificationSummary verification={summary.production_verification} /> · {summary.test.code} test code lines · assertions {summary.test_assertions ?? "unavailable"}</p>;
}

function InventoryPaths({ label, paths }: { readonly label: string; readonly paths: readonly string[] }): React.JSX.Element | null {
  return paths.length > 0 ? <p>{label}: {paths.join(", ")}</p> : null;
}

function FileReview({ file, onRaw, sideBySide }: { readonly file: DiffFile; readonly onRaw: (path: string) => void; readonly sideBySide: boolean }): React.JSX.Element {
  const [expanded, setExpanded] = useState(false);
  const publicGroups = file.groups.filter((group) => group.visibility !== "private" && (group.kind === "function" || group.kind === "class" || group.kind === "module"));
  const privateGroups = file.groups.filter((group) => group.visibility === "private");
  return <article className="file-review"><button aria-expanded={expanded} className="disclosure" onClick={() => setExpanded(!expanded)}>{file.path} · risk {file.risk.score} · {file.role} · {file.change} · {file.added_lines.code} code lines</button>
    {expanded && <div className="file-body">
      {!file.semantic_classification_available && <p className="metrics">Semantic classification unavailable; use the raw source-ordered diff.</p>}
      <RiskMetrics risk={file.risk} verification={file.verification} />
      <FindingSummary findings={file.sarif_findings} />
      {file.semantic_classification_available && publicGroups.sort(groupOrder).map((group) => <GroupReview file={file} group={group} key={`${group.kind}:${group.name}:${group.start_line}`} sideBySide={sideBySide} />)}
      <p>Other changed lines: {file.residual_lines.code} code, {file.residual_lines.comments} comments. <button onClick={() => onRaw(file.path)}>Open raw file diff</button></p>
      {(file.removed_lines.code > 0 || file.removed_lines.comments > 0) && <details><summary>Removals</summary><p>{file.removed_lines.code} code lines and {file.removed_lines.comments} comments removed; review in the raw diff.</p></details>}
      {file.semantic_classification_available && privateGroups.length > 0 && <PrivateReview file={file} groups={privateGroups} sideBySide={sideBySide} />}
      {(file.base_source === null || file.head_source === null) && <p>Binary or one-sided change; open the raw file view for details.</p>}
    </div>}
  </article>;
}

function PrivateReview({ file, groups, sideBySide }: { readonly file: DiffFile; readonly groups: readonly DiffGroup[]; readonly sideBySide: boolean }): React.JSX.Element {
  const [expanded, setExpanded] = useState(false);
  const added = groups.reduce(addAddedLines, emptyLines());
  const verification = groups.reduce(addVerification, emptyVerification());
  const hazards = groups.reduce((total, group) => total + group.risk.tier_one_hazards, 0);
  return <section><button aria-expanded={expanded} className="disclosure" onClick={() => setExpanded(!expanded)}>Private changes ({groups.length} functions, {added.code} code, +{groups.reduce((total, group) => total + group.risk.added_complexity, 0)} complexity, +{hazards} tier-1 hazards, <VerificationSummary verification={verification} />)</button>
    {expanded && groups.slice().sort(groupOrder).map((group) => <GroupReview file={file} group={group} key={`${group.kind}:${group.name}:${group.start_line}`} sideBySide={sideBySide} />)}
  </section>;
}

function GroupReview({ file, group, sideBySide }: { readonly file: DiffFile; readonly group: DiffGroup; readonly sideBySide: boolean }): React.JSX.Element {
  const [expanded, setExpanded] = useState(false);
  return <section className="group-review"><button aria-expanded={expanded} className="disclosure" onClick={() => setExpanded(!expanded)}>{group.kind} {group.name} · {group.added_lines.code} code lines · {group.added_lines.comments} comments</button>
    <RiskMetrics risk={group.risk} verification={group.verification} />
    <FindingSummary findings={group.sarif_findings} />
    {expanded && <DiffPreview highlights={relativeHighlights(group)} language={file.language ?? "plaintext"} modified={sourceRange(file.head_source, group.start_line, group.end_line)} original={sourceRange(file.base_source, group.base_start_line, group.base_end_line)} sideBySide={sideBySide} />}
  </section>;
}

function RawReview({ file, onBack, sideBySide }: { readonly file: DiffFile; readonly onBack: () => void; readonly sideBySide: boolean }): React.JSX.Element {
  return <article className="file-review"><button onClick={onBack}>Back to semantic review</button><h2>Raw diff: {file.path}</h2>{file.base_source !== null && file.head_source !== null ? <DiffPreview highlights={file.sarif_findings.map(findingHighlight)} language={file.language ?? "plaintext"} modified={file.head_source} original={file.base_source} sideBySide={sideBySide} /> : <p>Binary or one-sided change.</p>}</article>;
}

function RiskMetrics({ risk, verification }: { readonly risk: RiskSummary; readonly verification: VerificationSlices }): React.JSX.Element {
  return <p className="metrics"><VerificationSummary verification={verification} /> · +{risk.added_complexity} complexity · +{risk.tier_one_hazards} tier-1 hazards</p>;
}

function FindingSummary({ findings }: { readonly findings: DiffFile["sarif_findings"] }): React.JSX.Element | null {
  if (findings.length === 0) return null;
  return <p className="metrics">SARIF findings (partial): {findings.map((finding) => `${finding.tool}/${finding.rule_id} line ${finding.start_line}: ${finding.message}`).join(" · ")}</p>;
}

function sourceRange(source: string | null, start: number | null, end: number | null): string {
  if (source === null || start === null || end === null) return "";
  return source.split("\n").slice(start - 1, end).join("\n");
}

function groupOrder(left: DiffGroup, right: DiffGroup): number {
  return right.risk.score - left.risk.score || right.risk.tier_one_hazards - left.risk.tier_one_hazards || right.risk.not_covered - left.risk.not_covered || right.added_lines.code - left.added_lines.code || left.name.localeCompare(right.name);
}

function emptyLines(): AddedLines { return { code: 0, comments: 0, other: 0 }; }
function emptyVerification(): VerificationSlices { return { covered_and_killed: 0, covered: 0, partially_covered: 0, not_covered: 0, unknown: 0 }; }
function addAddedLines(total: AddedLines, group: DiffGroup): AddedLines {
  return { code: total.code + group.added_lines.code, comments: total.comments + group.added_lines.comments, other: total.other + group.added_lines.other };
}
function addVerification(total: VerificationSlices, group: DiffGroup): VerificationSlices {
  return {
    covered_and_killed: total.covered_and_killed + group.verification.covered_and_killed,
    covered: total.covered + group.verification.covered,
    partially_covered: total.partially_covered + group.verification.partially_covered,
    not_covered: total.not_covered + group.verification.not_covered,
    unknown: total.unknown + group.verification.unknown,
  };
}

function verificationTotal(verification: VerificationSlices): number {
  return verification.covered_and_killed + verification.covered + verification.partially_covered + verification.not_covered + verification.unknown;
}

function VerificationSummary({ verification }: { readonly verification: VerificationSlices }): React.JSX.Element {
  return <>{verification.covered_and_killed} covered+killed · {verification.covered} covered · {verification.partially_covered} partial · {verification.not_covered} not covered · {verification.unknown} unknown</>;
}

function relativeHighlights(group: DiffGroup): SourceHighlight[] {
  return group.sarif_findings.map((finding) => ({
    ...findingHighlight(finding),
    startLine: Math.max(1, finding.start_line - group.start_line + 1),
    endLine: Math.max(1, finding.end_line - group.start_line + 1),
  }));
}

function findingHighlight(finding: DiffFile["sarif_findings"][number]): SourceHighlight {
  return {
    startLine: finding.start_line,
    endLine: finding.end_line,
    title: `${finding.tool}/${finding.rule_id}: ${finding.message}`,
  };
}
