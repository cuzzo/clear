export function fixedKeywords(): number {
  const keywords = ["type", "enum", "const"];
  let count = 0;
  for (const keyword of keywords) {
    count += 1;
  }
  return count;
}

export function dynamicKeywords(keywords: string[]): number {
  let count = 0;
  for (const keyword of keywords) {
    count += 1;
  }
  return count;
}

export function grownKeywords(items: string[]): number {
  const keywords = ["type"];
  for (const item of items) {
    keywords.push(item);
  }
  let count = 0;
  for (const keyword of keywords) {
    count += 1;
  }
  return count;
}
