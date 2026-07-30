public class Unpriced {
  public int Count(string[] items) {
    int total = 0;
    foreach (var item in items) { total += Mystery.Weigh(item); }
    return total;
  }
}
