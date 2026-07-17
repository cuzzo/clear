using System;

class Registry {
  int Inspect(int[] values, string text) {
    Array.Copy(values, values, values.Length);
    return Array.BinarySearch(values, 1) + (int)Math.Sqrt(text.Length);
  }
}
