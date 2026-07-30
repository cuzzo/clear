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
}
