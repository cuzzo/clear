import { DiffEditor, type DiffOnMount, type Monaco } from "@monaco-editor/react";
import type { editor } from "monaco-editor";

export interface SourceHighlight {
  readonly startLine: number;
  readonly endLine: number;
  readonly title: string;
}

export interface DiffPreviewProps {
  readonly language: string;
  readonly modified: string;
  readonly original: string;
  readonly sideBySide?: boolean;
  readonly highlights?: readonly SourceHighlight[];
}

export function DiffPreview({ language, modified, original, sideBySide = true, highlights = [] }: DiffPreviewProps): React.JSX.Element {
  const onMount: DiffOnMount | undefined = highlights.length === 0 ? undefined : (editor, monaco) => {
    editor.getModifiedEditor().createDecorationsCollection(modifiedDecorations(highlights, monaco));
  };
  return (
    <DiffEditor
      height="18rem"
      language={language}
      modified={modified}
      onMount={onMount}
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

export function modifiedDecorations(highlights: readonly SourceHighlight[], monaco: Monaco): editor.IModelDeltaDecoration[] {
  return highlights.map((highlight) => ({
    options: {
      className: "lineage-sarif-line",
      hoverMessage: { value: highlight.title },
      isWholeLine: true,
      overviewRuler: { color: "#d29922", position: monaco.editor.OverviewRulerLane.Right },
    },
    range: new monaco.Range(Math.max(1, highlight.startLine), 1, Math.max(1, highlight.endLine), 1),
  }));
}
