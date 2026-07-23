const languageByExtension: Readonly<Record<string, string>> = {
  c: "c",
  cc: "cpp",
  cpp: "cpp",
  cs: "csharp",
  cxx: "cpp",
  go: "go",
  h: "c",
  hpp: "cpp",
  java: "java",
  js: "javascript",
  jsx: "javascript",
  json: "json",
  kt: "kotlin",
  kts: "kotlin",
  lua: "lua",
  m: "objective-c",
  md: "markdown",
  php: "php",
  py: "python",
  rb: "ruby",
  rs: "rust",
  swift: "swift",
  ts: "typescript",
  tsx: "typescript",
  yml: "yaml",
  yaml: "yaml",
  zig: "zig",
};

export function languageForPath(path: string): string {
  const extension = path.slice(path.lastIndexOf(".") + 1).toLowerCase();
  return languageByExtension[extension] ?? "plaintext";
}
