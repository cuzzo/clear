import { useEffect, useState } from "react";
import { DiffApiError, type DiffPlan, fetchDiffPlan, revisionsFromSearch } from "./api/diff";
import { DiffPreview } from "./monaco/DiffPreview";

export function App(): React.JSX.Element {
  const revisions = revisionsFromSearch(window.location.search);
  const [plan, setPlan] = useState<DiffPlan | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!revisions) return;
    void fetchDiffPlan(revisions).then(setPlan).catch((reason: unknown) => {
      setError(reason instanceof DiffApiError ? reason.message : "Unable to load diff plan");
    });
  }, [revisions?.base, revisions?.head]);

  return (
    <main className="app-shell">
      <header>
        <p className="eyebrow">Lineage</p>
        <h1>Revision-aware diff review</h1>
        <p>Revision-pinned inventory and raw source review.</p>
      </header>
      {!revisions && <p role="status">Add immutable base and head revisions to the URL to begin review.</p>}
      {error && <p role="alert">{error}</p>}
      {plan && <DiffReview plan={plan} />}
    </main>
  );
}

function DiffReview({ plan }: { readonly plan: DiffPlan }): React.JSX.Element {
  const [sideBySide, setSideBySide] = useState(true);
  return <section aria-label="Diff inventory" className="preview-card">
    <p>{plan.inventory.changed_files} files in {plan.inventory.changed_directories} directories</p>
    <p>Base {plan.scope.base_oid} · Head {plan.scope.head_oid}</p>
    {plan.dependency_changes.map((change) => <p key={change.manifest_path}>{change.manifest_path}: {change.status === "exact" ? "dependency changes parsed" : "unknown package-file change"}</p>)}
    {plan.language_summaries.map((summary) => <p key={summary.language}>{summary.language}: {summary.production.code} production code lines · {summary.test.code} test code lines</p>)}
    <fieldset><legend>Diff layout</legend><label><input checked={sideBySide} name="layout" onChange={() => setSideBySide(true)} type="radio" />Side by side</label><label><input checked={!sideBySide} name="layout" onChange={() => setSideBySide(false)} type="radio" />Inline</label></fieldset>
    {plan.files.map((file) => <FileReview file={file} key={file.path} sideBySide={sideBySide} />)}
  </section>;
}

function FileReview({ file, sideBySide }: { readonly file: DiffPlan["files"][number]; readonly sideBySide: boolean }): React.JSX.Element {
  const publicGroups = file.groups.filter((group) => group.visibility !== "private");
  const privateGroups = file.groups.filter((group) => group.visibility === "private");
  return <details><summary>{file.path} · {file.role} · {file.change} · {file.added_lines.code} code lines</summary>
    {publicGroups.map((group) => <GroupReview file={file} group={group} key={`${group.kind}:${group.name}:${group.start_line}`} sideBySide={sideBySide} />)}
    {file.base_source !== null && file.head_source !== null && publicGroups.length === 0 && <DiffPreview language={file.language ?? "plaintext"} modified={file.head_source} original={file.base_source} sideBySide={sideBySide} />}
    {file.base_source === null || file.head_source === null ? <p>Binary or one-sided change; open the raw file view for details.</p> : null}
    {privateGroups.length > 0 && <details><summary>{privateGroups.length} private changes · {privateGroups.reduce((total, group) => total + group.added_lines.code, 0)} code lines</summary>{privateGroups.map((group) => <GroupReview file={file} group={group} key={`${group.kind}:${group.name}:${group.start_line}`} sideBySide={sideBySide} />)}</details>}
  </details>;
}

function GroupReview({ file, group, sideBySide }: { readonly file: DiffPlan["files"][number]; readonly group: DiffPlan["files"][number]["groups"][number]; readonly sideBySide: boolean }): React.JSX.Element {
  return <details><summary>{group.kind} {group.name} · {group.added_lines.code} code lines · {group.added_lines.comments} comments</summary>{file.base_source !== null && file.head_source !== null ? <DiffPreview language={file.language ?? "plaintext"} modified={file.head_source} original={file.base_source} sideBySide={sideBySide} /> : null}</details>;
}
