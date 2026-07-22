class NullableJava {
  int unsafe() {
    String value = null;
    return value.length();
  }

  int guarded() {
    String value = null;
    if (value == null) {
      return 0;
    }
    return value.length();
  }
}
