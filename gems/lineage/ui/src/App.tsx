import { DiffPreview } from "./monaco/DiffPreview";
import { languageForPath } from "./monaco/language";

const previewPath = "src/example.rb";
const original = "def normalize(name)\n  name\nend\n";
const modified = "def normalize(name)\n  name.strip\nend\n";

export function App(): React.JSX.Element {
  return (
    <main className="app-shell">
      <header>
        <p className="eyebrow">Lineage</p>
        <h1>Revision-aware diff review</h1>
        <p>
          The React and Monaco foundation is ready for the revision-pinned evidence API.
        </p>
      </header>
      <section aria-labelledby="preview-heading" className="preview-card">
        <div>
          <p className="eyebrow">Monaco integration</p>
          <h2 id="preview-heading">Typed diff surface</h2>
        </div>
        <DiffPreview
          language={languageForPath(previewPath)}
          modified={modified}
          original={original}
        />
      </section>
    </main>
  );
}
