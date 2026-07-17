import java.util.ArrayList;

class TypedCollections {
  String[] copyIfPresent(ArrayList<String> values, String needle) {
    if (values.contains(needle)) {
      return values.toArray(new String[0]);
    }
    return new String[0];
  }
}
