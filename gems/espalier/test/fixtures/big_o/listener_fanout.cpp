struct Listener {
  void run();
};

int sum(int values[], int count) {
  int total = 0;
  for (int index = 0; index < count; index++) {
    total += values[index];
  }
  return total;
}

void dispatch(Listener listeners[], int count) {
  for (int index = 0; index < count; index++) {
    listeners[index].run();
  }
}
