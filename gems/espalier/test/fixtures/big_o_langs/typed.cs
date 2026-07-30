using System.Collections.Generic;
using System.Text;

public class Typed {
  public int SumLengths(List<string> items) {
    int total = 0;
    foreach (string item in items) { total += item.Length; }
    return total;
  }

  public string Join(List<string> items) {
    StringBuilder sb = new StringBuilder();
    foreach (string item in items) { sb.Append(item); }
    return sb.ToString();
  }

  public bool Has(Dictionary<string, int> index, string key) {
    return index.ContainsKey(key);
  }

  public List<string> Copy(List<string> items) {
    List<string> output = new List<string>();
    foreach (string item in items) { output.Add(item); }
    return output;
  }

  // A scalar comparison is a machine instruction, not an unpriced call.
  public int CountDown(long limit) {
    int steps = 0;
    for (long n = limit; n > 0; n--) { steps++; }
    return steps;
  }
}
