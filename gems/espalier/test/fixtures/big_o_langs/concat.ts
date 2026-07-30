export function build(parts: string[]): string {
  let out = "";
  for (const part of parts) { out = out + part; }
  return out;
}
