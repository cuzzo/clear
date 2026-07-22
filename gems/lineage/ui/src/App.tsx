import { useEffect, useState } from "react";
import { DiffApiError, type AddedLines, type DependencyChange, type DiffFile, type DiffGroup, type DiffPlan, type DiffRequest, type RiskSummary, type VerificationSlices, fetchDiffPlan, revisionsFromSearch } from "./api/diff";
import { DiffPreview, type SourceHighlight } from "./monaco/DiffPreview";

export const FILES_PER_PAGE = 50;

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
  }, [revisions?.base, revisions?.head, revisions?.coverage_source, revisions?.selection, revisions?.mutant_corpus, revisions?.test_set, revisions?.page, revisions?.path]);

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
      {plan && <DiffReview initialLayout={initialLayout} page={pageFromSearch(location)} plan={plan} rawPath={query.get("presentation") === "raw" ? query.get("path") : null} selectedGroup={query.get("group")} />}
    </main>
  );
}

function DiffReview({ initialLayout, page, plan, rawPath, selectedGroup }: { readonly initialLayout: "inline" | "split"; readonly page: number; readonly plan: DiffPlan; readonly rawPath: string | null; readonly selectedGroup: string | null }): React.JSX.Element {
  const [sideBySide, setSideBySide] = useState(() => initialLayout === "split");
  const rawFile = rawPath ? plan.files.find((file) => file.path === rawPath) : undefined;
  const pageCount = Math.max(1, Math.ceil(plan.files.length / FILES_PER_PAGE));
  const anchoredFileIndex = selectedGroup === null ? -1 : plan.files.findIndex((file) => file.groups.some((group) => groupIdentity(file, group) === selectedGroup));
  const selectedPage = anchoredFileIndex >= 0 ? Math.floor(anchoredFileIndex / FILES_PER_PAGE) + 1 : Math.min(page, pageCount);
  const visibleFiles = plan.files.slice((selectedPage - 1) * FILES_PER_PAGE, selectedPage * FILES_PER_PAGE);
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
    nextQuery.delete("group");
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
  const selectPage = (nextPage: number) => {
    const nextQuery = new URLSearchParams(window.location.search);
    if (nextPage === 1) nextQuery.delete("page"); else nextQuery.set("page", String(nextPage));
    nextQuery.delete("group");
    nextQuery.delete("path");
    window.history.pushState({}, "", `${window.location.pathname}?${nextQuery}`);
    window.dispatchEvent(new PopStateEvent("popstate"));
  };
  const selectGroup = (file: DiffFile, group: DiffGroup | null) => {
    const nextQuery = new URLSearchParams(window.location.search);
    if (group === null) {
      nextQuery.delete("group");
      nextQuery.delete("path");
    } else {
      nextQuery.set("group", groupIdentity(file, group));
      nextQuery.set("path", file.path);
    }
    window.history.pushState({}, "", `${window.location.pathname}?${nextQuery}`);
    window.dispatchEvent(new PopStateEvent("popstate"));
  };
  return <section aria-label="Diff inventory" className="preview-card">
    <p>{plan.inventory.changed_files} files in {plan.inventory.changed_directories} directories</p>
    <p>{plan.inventory.added_files} added · {plan.inventory.modified_files} modified · {plan.inventory.deleted_files} deleted · {plan.inventory.renamed_files} renamed</p>
    <p>Base {plan.scope.base_oid} · Head {plan.scope.head_oid}</p>
    <p>Evidence scope: {plan.scope.evidence_scope.selection} · {plan.scope.evidence_scope.mutant_corpus} · {plan.scope.evidence_scope.test_set}</p>
    <p>Evidence: coverage {plan.evidence.coverage} · mutation {plan.evidence.mutation} · hazards {plan.evidence.hazards} · SARIF {plan.evidence.sarif}</p>
    {plan.resolved_sarif_findings.length > 0 && <p>Resolved SARIF findings: {plan.resolved_sarif_findings.map((entry) => `${entry.path} ${entry.finding.tool}/${entry.finding.rule_id} line ${entry.finding.start_line}: ${entry.finding.message}`).join(" · ")}</p>}
    <InventoryPaths label="Configuration" paths={plan.inventory.configuration_paths.map((file) => `${file.path} (${file.kind})`)} />
    <InventoryPaths label="Documentation" paths={plan.inventory.documentation_paths} />
    <InventoryPaths label="Generated" paths={plan.inventory.generated_paths} />
    <InventoryPaths label="Lockfiles" paths={plan.inventory.lockfile_paths} />
    {plan.dependency_changes.map((change) => <DependencySummary change={change} key={change.manifest_path} />)}
    {plan.language_summaries.map((summary) => <LanguageSummaryCard key={summary.language} summary={summary} />)}
    <fieldset><legend>Diff layout</legend><label><input checked={sideBySide} name="layout" onChange={() => setLayout(true)} type="radio" />Side by side</label><label><input checked={!sideBySide} name="layout" onChange={() => setLayout(false)} type="radio" />Inline</label></fieldset>
    {rawFile ? <RawReview file={rawFile} headOid={plan.scope.head_oid} onBack={closeRaw} sideBySide={sideBySide} /> : <><PageControls onPage={selectPage} page={selectedPage} pageCount={pageCount} totalFiles={plan.files.length} />{visibleFiles.map((file) => <FileReview file={file} headOid={plan.scope.head_oid} key={file.path} onGroupChange={selectGroup} onRaw={openRaw} selectedGroup={selectedGroup} sideBySide={sideBySide} />)}</>}
  </section>;
}

export function pageFromSearch(search: string): number {
  const value = Number(new URLSearchParams(search).get("page"));
  return Number.isSafeInteger(value) && value > 1 ? value : 1;
}

export function PageControls({ onPage, page, pageCount, totalFiles }: { readonly onPage: (page: number) => void; readonly page: number; readonly pageCount: number; readonly totalFiles: number }): React.JSX.Element | null {
  if (pageCount <= 1) return null;
  const first = (page - 1) * FILES_PER_PAGE + 1;
  const last = Math.min(totalFiles, page * FILES_PER_PAGE);
  return <nav aria-label="Diff file pages"><p>Showing files {first}–{last} of {totalFiles}</p><button disabled={page === 1} onClick={() => onPage(page - 1)}>Previous files</button><button disabled={page === pageCount} onClick={() => onPage(page + 1)}>Next files</button></nav>;
}

function RevisionControls({ revisions }: { readonly revisions: DiffRequest | null }): React.JSX.Element {
  const [base, setBase] = useState(revisions?.base ?? "");
  const [head, setHead] = useState(revisions?.head ?? "");
  const [coverageSource, setCoverageSource] = useState(revisions?.coverage_source ?? "");
  const [sarifSource, setSarifSource] = useState(revisions?.sarif_source ?? "");
  const [selection, setSelection] = useState(revisions?.selection ?? "");
  const [mutantCorpus, setMutantCorpus] = useState(revisions?.mutant_corpus ?? "");
  const [testSet, setTestSet] = useState(revisions?.test_set ?? "");
  useEffect(() => {
    setBase(revisions?.base ?? "");
    setHead(revisions?.head ?? "");
    setCoverageSource(revisions?.coverage_source ?? "");
    setSarifSource(revisions?.sarif_source ?? "");
    setSelection(revisions?.selection ?? "");
    setMutantCorpus(revisions?.mutant_corpus ?? "");
    setTestSet(revisions?.test_set ?? "");
  }, [revisions?.base, revisions?.head, revisions?.coverage_source, revisions?.sarif_source, revisions?.selection, revisions?.mutant_corpus, revisions?.test_set]);
  const chooseRevisions = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!base.trim() || !head.trim()) return;
    const next = new URLSearchParams(window.location.search);
    next.set("base", base.trim());
    next.set("head", head.trim());
    for (const [name, value] of [["coverage_source", coverageSource], ["sarif_source", sarifSource], ["selection", selection], ["mutant_corpus", mutantCorpus], ["test_set", testSet]] as const) {
      if (value.trim()) next.set(name, value.trim()); else next.delete(name);
    }
    next.delete("presentation");
    next.delete("path");
    next.delete("group");
    window.history.pushState({}, "", `${window.location.pathname}?${next}`);
    window.dispatchEvent(new PopStateEvent("popstate"));
  };
  return <form aria-label="Revision comparison" className="revision-controls" onSubmit={chooseRevisions}>
    <label>Base revision <input aria-label="Base revision" onChange={(event) => setBase(event.target.value)} required value={base} /></label>
    <label>Head revision <input aria-label="Head revision" onChange={(event) => setHead(event.target.value)} required value={head} /></label>
    <details><summary>Evidence selection</summary>
      <label>Coverage source <input aria-label="Coverage source" onChange={(event) => setCoverageSource(event.target.value)} value={coverageSource} /></label>
      <label>SARIF source <input aria-label="SARIF source" onChange={(event) => setSarifSource(event.target.value)} value={sarifSource} /></label>
      <label>Selection <input aria-label="Evidence selection" onChange={(event) => setSelection(event.target.value)} value={selection} /></label>
      <label>Mutant corpus <input aria-label="Mutant corpus" onChange={(event) => setMutantCorpus(event.target.value)} value={mutantCorpus} /></label>
      <label>Test set <input aria-label="Test set" onChange={(event) => setTestSet(event.target.value)} value={testSet} /></label>
    </details>
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
  return <p>{summary.language}: {summary.production.code} production code lines · {summary.production.comments} production comments · public {verificationTotal(visibility.public)} · private {verificationTotal(visibility.private)} · unknown visibility {verificationTotal(visibility.unknown)} · <VerificationSummary verification={summary.production_verification} /> · {summary.test.code} test code lines · {summary.test.comments} test comments · assertions {summary.test_assertions ?? "unavailable"}</p>;
}

function InventoryPaths({ label, paths }: { readonly label: string; readonly paths: readonly string[] }): React.JSX.Element | null {
  return paths.length > 0 ? <p>{label}: {paths.join(", ")}</p> : null;
}

function FileReview({ file, headOid, onGroupChange, onRaw, selectedGroup, sideBySide }: { readonly file: DiffFile; readonly headOid: string; readonly onGroupChange: (file: DiffFile, group: DiffGroup | null) => void; readonly onRaw: (path: string) => void; readonly selectedGroup: string | null; readonly sideBySide: boolean }): React.JSX.Element {
  const [expanded, setExpanded] = useState(false);
  const publicGroups = file.groups.filter((group) => group.visibility !== "private" && (group.kind === "function" || group.kind === "class" || group.kind === "module"));
  const privateGroups = file.groups.filter((group) => group.visibility === "private");
  useEffect(() => {
    if (selectedGroup !== null && file.groups.some((group) => groupIdentity(file, group) === selectedGroup)) setExpanded(true);
  }, [file, selectedGroup]);
  return <article className="file-review"><button aria-expanded={expanded} className="disclosure" onClick={() => setExpanded(!expanded)}>{file.path} · risk {file.risk.score} · {file.role} · {file.change} · {file.added_lines.code} code lines</button> <a href={sourceUrl(file.path, headOid)}>Open source</a>
    {expanded && <div className="file-body">
      {!file.semantic_classification_available && <p className="metrics">Semantic classification unavailable; use the raw source-ordered diff.</p>}
      <RiskMetrics risk={file.risk} verification={file.verification} />
      <FindingSummary findings={file.sarif_findings} />
      {file.semantic_classification_available && publicGroups.sort(groupOrder).map((group) => <GroupReview file={file} group={group} key={`${group.kind}:${group.name}:${group.start_line}`} onGroupChange={onGroupChange} selectedGroup={selectedGroup} sideBySide={sideBySide} />)}
      <p>Other changed lines: {file.residual_lines.code} code, {file.residual_lines.comments} comments. <button onClick={() => onRaw(file.path)}>Open raw file diff</button></p>
      {(file.removed_lines.code > 0 || file.removed_lines.comments > 0) && <details><summary>Removals</summary><p>{file.removed_lines.code} code lines and {file.removed_lines.comments} comments removed; review in the raw diff.</p></details>}
      {file.semantic_classification_available && privateGroups.length > 0 && <PrivateReview file={file} groups={privateGroups} onGroupChange={onGroupChange} selectedGroup={selectedGroup} sideBySide={sideBySide} />}
      {(file.base_source === null || file.head_source === null) && <p>Binary or one-sided change; open the raw file view for details.</p>}
    </div>}
  </article>;
}

function PrivateReview({ file, groups, onGroupChange, selectedGroup, sideBySide }: { readonly file: DiffFile; readonly groups: readonly DiffGroup[]; readonly onGroupChange: (file: DiffFile, group: DiffGroup | null) => void; readonly selectedGroup: string | null; readonly sideBySide: boolean }): React.JSX.Element {
  const [expanded, setExpanded] = useState(false);
  const added = groups.reduce(addAddedLines, emptyLines());
  const verification = groups.reduce(addVerification, emptyVerification());
  const hazards = groups.reduce((total, group) => total + group.risk.tier_one_hazards, 0);
  return <section><button aria-expanded={expanded} className="disclosure" onClick={() => setExpanded(!expanded)}>Private changes ({groups.length} functions, {added.code} code, +{groups.reduce((total, group) => total + group.risk.added_complexity, 0)} complexity, +{hazards} tier-1 hazards, <VerificationSummary verification={verification} />)</button>
    {expanded && groups.slice().sort(groupOrder).map((group) => <GroupReview file={file} group={group} key={`${group.kind}:${group.name}:${group.start_line}`} onGroupChange={onGroupChange} selectedGroup={selectedGroup} sideBySide={sideBySide} />)}
  </section>;
}

function GroupReview({ file, group, onGroupChange, selectedGroup, sideBySide }: { readonly file: DiffFile; readonly group: DiffGroup; readonly onGroupChange: (file: DiffFile, group: DiffGroup | null) => void; readonly selectedGroup: string | null; readonly sideBySide: boolean }): React.JSX.Element {
  const identity = groupIdentity(file, group);
  const [expanded, setExpanded] = useState(() => selectedGroup === identity);
  useEffect(() => setExpanded(selectedGroup === identity), [identity, selectedGroup]);
  const toggle = () => {
    const next = !expanded;
    setExpanded(next);
    onGroupChange(file, next ? group : null);
  };
  return <section className="group-review"><button aria-expanded={expanded} className="disclosure" onClick={toggle}>{group.kind} {group.name} · {group.added_lines.code} code lines · {group.added_lines.comments} comments</button>
    <RiskMetrics risk={group.risk} verification={group.verification} />
    <FindingSummary findings={group.sarif_findings} />
    {expanded && <DiffPreview annotations={relativeAnnotations(file.line_annotations, group.start_line, group.end_line)} highlights={relativeHighlights(group)} language={file.language ?? "plaintext"} modified={sourceRange(file.head_source, group.start_line, group.end_line)} original={sourceRange(file.base_source, group.base_start_line, group.base_end_line)} sideBySide={sideBySide} />}
  </section>;
}

function RawReview({ file, headOid, onBack, sideBySide }: { readonly file: DiffFile; readonly headOid: string; readonly onBack: () => void; readonly sideBySide: boolean }): React.JSX.Element {
  return <article className="file-review"><button onClick={onBack}>Back to semantic review</button><h2>Raw diff: {file.path}</h2><a href={sourceUrl(file.path, headOid)}>Open source</a>{file.base_source !== null && file.head_source !== null ? <DiffPreview annotations={file.line_annotations} highlights={file.sarif_findings.map(findingHighlight)} language={file.language ?? "plaintext"} modified={file.head_source} original={file.base_source} sideBySide={sideBySide} /> : <p>Binary or one-sided change.</p>}</article>;
}

function RiskMetrics({ risk, verification }: { readonly risk: RiskSummary; readonly verification: VerificationSlices }): React.JSX.Element {
  return <p className="metrics"><VerificationSummary verification={verification} /> · +{risk.added_complexity} complexity · +{risk.tier_one_hazards} tier-1 hazards</p>;
}

function FindingSummary({ findings }: { readonly findings: DiffFile["sarif_findings"] }): React.JSX.Element | null {
  if (findings.length === 0) return null;
  return <p className="metrics">SARIF findings: {findings.map((finding) => `${finding.status} ${finding.level}/${finding.category} ${finding.tier === null ? "unclassified tier" : `tier-${finding.tier}`} ${finding.tool}/${finding.rule_id} line ${finding.start_line}: ${finding.message}`).join(" · ")}</p>;
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

function relativeAnnotations(annotations: readonly import("./api/diff").LineAnnotation[], startLine: number, endLine: number): import("./api/diff").LineAnnotation[] {
  return annotations
    .filter((annotation) => annotation.line >= startLine && annotation.line <= endLine)
    .map((annotation) => ({ ...annotation, line: annotation.line - startLine + 1 }));
}

function findingHighlight(finding: DiffFile["sarif_findings"][number]): SourceHighlight {
  return {
    startLine: finding.start_line,
    endLine: finding.end_line,
    title: `${finding.tool}/${finding.rule_id}: ${finding.message}`,
  };
}

function sourceUrl(path: string, commit: string): string {
  const query = new URLSearchParams({ path, commit });
  return `/?${query}#L1`;
}

export function groupIdentity(file: DiffFile, group: DiffGroup): string {
  return `${file.path}:${group.kind}:${group.name}:${group.start_line}`;
}
