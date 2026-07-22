import { DiffEditor } from "@monaco-editor/react";

export interface DiffPreviewProps {
  readonly language: string;
  readonly modified: string;
  readonly original: string;
}

export function DiffPreview({ language, modified, original }: DiffPreviewProps): React.JSX.Element {
  return (
    <DiffEditor
      height="18rem"
      language={language}
      modified={modified}
      options={{
        automaticLayout: true,
        minimap: { enabled: false },
        readOnly: true,
        renderSideBySide: true,
      }}
      original={original}
      theme="vs-dark"
    />
  );
}
