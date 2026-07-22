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
  return <section aria-label="Diff inventory" className="preview-card">
    <p>{plan.inventory.changed_files} files in {plan.inventory.changed_directories} directories</p>
    <p>Base {plan.scope.base_oid} · Head {plan.scope.head_oid}</p>
    {plan.dependency_changes.map((change) => <p key={change.manifest_path}>{change.manifest_path}: {change.status === "exact" ? "dependency changes parsed" : "unknown package-file change"}</p>)}
    {plan.files.map((file) => <details key={file.path}><summary>{file.path} · {file.role} · {file.change}</summary>{file.base_source !== null && file.head_source !== null ? <DiffPreview language={file.language ?? "plaintext"} original={file.base_source} modified={file.head_source} /> : <p>Binary or one-sided change; open the raw file view for details.</p>}</details>)}
  </section>;
}
