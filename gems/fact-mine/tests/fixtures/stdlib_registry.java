import java.util.Arrays;
import java.util.Objects;

class Registry {
  int inspect(int[] values, String text) {
    Objects.requireNonNull(text);
    int[] copy = Arrays.copyOf(values, values.length);
    return Arrays.binarySearch(copy, 1) + (int) Math.sqrt(copy.length);
  }
}
