export const double = (value: number): number => {
  return value * 2;
};

export const increment = function (value: number): number {
  return value + 1;
};

export function useCallable(value: number): number {
  return increment(double(value));
}

export function useNestedCallable(value: number): number {
  const nested = () => increment(value);
  return nested();
}
