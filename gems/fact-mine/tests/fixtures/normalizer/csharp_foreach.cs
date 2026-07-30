public class F {
  public int Sum(int[] xs) {
    int t = 0;
    foreach (int x in xs) { t += x; }
    return t;
  }
}
