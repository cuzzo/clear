import { DiffEditor, type DiffOnMount, type Monaco } from "@monaco-editor/react";
import type { editor } from "monaco-editor";
import type { LineAnnotation } from "../api/diff";

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
  readonly annotations?: readonly LineAnnotation[];
}

export function DiffPreview({ language, modified, original, sideBySide = true, highlights = [], annotations = [] }: DiffPreviewProps): React.JSX.Element {
  const onMount: DiffOnMount | undefined = highlights.length === 0 && annotations.length === 0 ? undefined : (editor, monaco) => {
    editor.getModifiedEditor().createDecorationsCollection([
      ...modifiedDecorations(highlights, monaco),
      ...verificationDecorations(annotations, monaco),
    ]);
  };
  return (
    <DiffEditor
      height="18rem"
      language={language}
      modified={modified}
      onMount={onMount}
      options={{
        automaticLayout: true,
        glyphMargin: annotations.length > 0,
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

export function verificationDecorations(annotations: readonly LineAnnotation[], monaco: Monaco): editor.IModelDeltaDecoration[] {
  return annotations.map((annotation) => ({
    options: {
      className: `lineage-verification-${annotation.verification}`,
      glyphMarginClassName: `lineage-verification-glyph-${annotation.verification}`,
      hoverMessage: { value: verificationLabel(annotation.verification) },
      isWholeLine: true,
      overviewRuler: { color: verificationColor(annotation.verification), position: monaco.editor.OverviewRulerLane.Right },
    },
    range: new monaco.Range(Math.max(1, annotation.line), 1, Math.max(1, annotation.line), 1),
  }));
}

function verificationLabel(verification: LineAnnotation["verification"]): string {
  return `Lineage verification: ${verification.replaceAll("_", " ")}`;
}

function verificationColor(verification: LineAnnotation["verification"]): string {
  return ({
    covered_and_killed: "#3fb950",
    covered: "#58a6ff",
    partially_covered: "#d29922",
    not_covered: "#f85149",
    unknown: "#8b949e",
  })[verification];
}
