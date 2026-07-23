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

  int guardedDisjunction(int flag) {
    String value = null;
    if (value == null || flag == 5) {
      return 0;
    } else {
      return value.length();
    }
  }
}
