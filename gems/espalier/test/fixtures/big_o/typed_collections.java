import java.util.List;

class TypedCollections {
  String[] copyIfPresent(List<String> values, String needle) {
    if (values.contains(needle)) {
      return values.toArray(new String[0]);
    }
    return new String[0];
  }
}
