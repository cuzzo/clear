export function sumLengths(items: string[]): number {
  let total = 0;
  for (const item of items) { total += item.length; }
  return total;
}

export function lookup(index: Map<string, number>, key: string): number {
  const found = index.get(key);
  return found === undefined ? 0 : found;
}

export function copy(items: string[]): string[] {
  const output: string[] = [];
  for (const item of items) { output.push(item); }
  return output;
}

// The cursor's type comes from what it is initialized from, so its comparison
// is priced and the descent in the header is visible.
export function divideDescent(limit: number): number {
  let steps = 0;
  for (let n = limit; n > 1; n /= 2) { steps++; }
  return steps;
}
