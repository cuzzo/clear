export function classify(value) {
  if (value > 10) return "high";
  if (value > 0) return "positive";
  return "nonpositive";
}
