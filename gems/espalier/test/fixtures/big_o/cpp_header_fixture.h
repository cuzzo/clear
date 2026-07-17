namespace fixture {
int sum(int values[], int count) {
  int total = 0;
  for (int index = 0; index < count; index++) {
    total += values[index];
  }
  return total;
}
}
