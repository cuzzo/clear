public class Concat {
  public string Build(string[] parts) {
    string outText = "";
    foreach (var part in parts) { outText = outText + part; }
    return outText;
  }
}
