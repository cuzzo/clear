import { useEffect, useState } from "react";
import { DiffApiError, type AddedLines, type DiffFile, type DiffGroup, type DiffPlan, type RiskSummary, type VerificationSlices, fetchDiffPlan, revisionsFromSearch } from "./api/diff";
import { DiffPreview } from "./monaco/DiffPreview";

export function App(): React.JSX.Element {
  const [location, setLocation] = useState(window.location.search);
  const revisions = revisionsFromSearch(location);
  const query = new URLSearchParams(location);
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
      {!revisions && <p role="status">Add immutable base and head revisions to the URL to begin review.</p>}
      {error && <p role="alert">{error}</p>}
      {plan && <DiffReview initialLayout={query.get("layout") === "inline" ? "inline" : "split"} plan={plan} rawPath={query.get("presentation") === "raw" ? query.get("path") : null} />}
    </main>
  );
}

function DiffReview({ initialLayout, plan, rawPath }: { readonly initialLayout: "inline" | "split"; readonly plan: DiffPlan; readonly rawPath: string | null }): React.JSX.Element {
  const [sideBySide, setSideBySide] = useState(initialLayout === "split");
  const rawFile = rawPath ? plan.files.find((file) => file.path === rawPath) : undefined;
  const setLayout = (next: boolean) => {
    const nextQuery = new URLSearchParams(window.location.search);
    nextQuery.set("layout", next ? "split" : "inline");
    window.history.replaceState({}, "", `${window.location.pathname}?${nextQuery}`);
    setSideBySide(next);
  };
  const openRaw = (path: string) => {
    const nextQuery = new URLSearchParams(window.location.search);
    nextQuery.set("presentation", "raw");
    nextQuery.set("path", path);
    window.history.replaceState({}, "", `${window.location.pathname}?${nextQuery}`);
    window.dispatchEvent(new PopStateEvent("popstate"));
  };
  const closeRaw = () => {
    const nextQuery = new URLSearchParams(window.location.search);
    nextQuery.delete("presentation");
    nextQuery.delete("path");
    window.history.replaceState({}, "", `${window.location.pathname}?${nextQuery}`);
    window.dispatchEvent(new PopStateEvent("popstate"));
  };
  return <section aria-label="Diff inventory" className="preview-card">
    <p>{plan.inventory.changed_files} files in {plan.inventory.changed_directories} directories</p>
    <p>Base {plan.scope.base_oid} · Head {plan.scope.head_oid}</p>
    <p>Evidence: coverage {plan.evidence.coverage} · mutation {plan.evidence.mutation} · hazards {plan.evidence.hazards}</p>
    {plan.dependency_changes.map((change) => <p key={change.manifest_path}>{change.manifest_path}: {change.status === "exact" ? "dependency changes parsed" : "unknown package-file change"}</p>)}
    {plan.language_summaries.map((summary) => <p key={summary.language}>{summary.language}: {summary.production.code} production code lines · {summary.test.code} test code lines</p>)}
    <fieldset><legend>Diff layout</legend><label><input checked={sideBySide} name="layout" onChange={() => setLayout(true)} type="radio" />Side by side</label><label><input checked={!sideBySide} name="layout" onChange={() => setLayout(false)} type="radio" />Inline</label></fieldset>
    {rawFile ? <RawReview file={rawFile} onBack={closeRaw} sideBySide={sideBySide} /> : plan.files.map((file) => <FileReview file={file} key={file.path} onRaw={openRaw} sideBySide={sideBySide} />)}
  </section>;
}

function FileReview({ file, onRaw, sideBySide }: { readonly file: DiffFile; readonly onRaw: (path: string) => void; readonly sideBySide: boolean }): React.JSX.Element {
  const [expanded, setExpanded] = useState(false);
  const publicGroups = file.groups.filter((group) => group.visibility !== "private" && (group.kind === "function" || group.kind === "class" || group.kind === "module"));
  const privateGroups = file.groups.filter((group) => group.visibility === "private");
  return <article className="file-review"><button aria-expanded={expanded} className="disclosure" onClick={() => setExpanded(!expanded)}>{file.path} · risk {file.risk.score} · {file.role} · {file.change} · {file.added_lines.code} code lines</button>
    {expanded && <div className="file-body">
      <RiskMetrics risk={file.risk} verification={file.verification} />
      {publicGroups.sort(groupOrder).map((group) => <GroupReview file={file} group={group} key={`${group.kind}:${group.name}:${group.start_line}`} sideBySide={sideBySide} />)}
      <p>Other changed lines: {file.residual_lines.code} code, {file.residual_lines.comments} comments. <button onClick={() => onRaw(file.path)}>Open raw file diff</button></p>
      {privateGroups.length > 0 && <PrivateReview file={file} groups={privateGroups} sideBySide={sideBySide} />}
      {(file.base_source === null || file.head_source === null) && <p>Binary or one-sided change; open the raw file view for details.</p>}
    </div>}
  </article>;
}

function PrivateReview({ file, groups, sideBySide }: { readonly file: DiffFile; readonly groups: readonly DiffGroup[]; readonly sideBySide: boolean }): React.JSX.Element {
  const [expanded, setExpanded] = useState(false);
  const added = groups.reduce(addAddedLines, emptyLines());
  return <section><button aria-expanded={expanded} className="disclosure" onClick={() => setExpanded(!expanded)}>Private changes ({groups.length} functions, {added.code} code, +{groups.reduce((total, group) => total + group.risk.added_complexity, 0)} complexity)</button>
    {expanded && groups.slice().sort(groupOrder).map((group) => <GroupReview file={file} group={group} key={`${group.kind}:${group.name}:${group.start_line}`} sideBySide={sideBySide} />)}
  </section>;
}

function GroupReview({ file, group, sideBySide }: { readonly file: DiffFile; readonly group: DiffGroup; readonly sideBySide: boolean }): React.JSX.Element {
  const [expanded, setExpanded] = useState(false);
  return <section className="group-review"><button aria-expanded={expanded} className="disclosure" onClick={() => setExpanded(!expanded)}>{group.kind} {group.name} · {group.added_lines.code} code lines · {group.added_lines.comments} comments</button>
    <RiskMetrics risk={group.risk} verification={group.verification} />
    {expanded && <DiffPreview language={file.language ?? "plaintext"} modified={sourceRange(file.head_source, group.start_line, group.end_line)} original={sourceRange(file.base_source, group.base_start_line, group.base_end_line)} sideBySide={sideBySide} />}
  </section>;
}

function RawReview({ file, onBack, sideBySide }: { readonly file: DiffFile; readonly onBack: () => void; readonly sideBySide: boolean }): React.JSX.Element {
  return <article className="file-review"><button onClick={onBack}>Back to semantic review</button><h2>Raw diff: {file.path}</h2>{file.base_source !== null && file.head_source !== null ? <DiffPreview language={file.language ?? "plaintext"} modified={file.head_source} original={file.base_source} sideBySide={sideBySide} /> : <p>Binary or one-sided change.</p>}</article>;
}

function RiskMetrics({ risk, verification }: { readonly risk: RiskSummary; readonly verification: VerificationSlices }): React.JSX.Element {
  return <p className="metrics">{risk.not_covered} not covered · {risk.partially_covered} partial · +{risk.added_complexity} complexity · +{risk.tier_one_hazards} tier-1 hazards · {verification.unknown} unknown evidence</p>;
}

function sourceRange(source: string | null, start: number | null, end: number | null): string {
  if (source === null || start === null || end === null) return "";
  return source.split("\n").slice(start - 1, end).join("\n");
}

function groupOrder(left: DiffGroup, right: DiffGroup): number {
  return right.risk.score - left.risk.score || right.risk.tier_one_hazards - left.risk.tier_one_hazards || right.risk.not_covered - left.risk.not_covered || right.added_lines.code - left.added_lines.code || left.name.localeCompare(right.name);
}

function emptyLines(): AddedLines { return { code: 0, comments: 0, other: 0 }; }
function addAddedLines(total: AddedLines, group: DiffGroup): AddedLines {
  return { code: total.code + group.added_lines.code, comments: total.comments + group.added_lines.comments, other: total.other + group.added_lines.other };
}
