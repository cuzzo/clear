import { DiffEditor } from "@monaco-editor/react";

export interface DiffPreviewProps {
  readonly language: string;
  readonly modified: string;
  readonly original: string;
  readonly sideBySide?: boolean;
}

export function DiffPreview({ language, modified, original, sideBySide = true }: DiffPreviewProps): React.JSX.Element {
  return (
    <DiffEditor
      height="18rem"
      language={language}
      modified={modified}
      options={{
        automaticLayout: true,
        minimap: { enabled: false },
        readOnly: true,
        renderSideBySide: sideBySide,
      }}
      original={original}
      theme="vs-dark"
    />
  );
}
