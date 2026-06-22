class Example {
  static void stable_one(Node node) { node.storage = 1; node.provenance = 1; }
  static void stable_two(Node node) { node.storage = 1; node.provenance = 1; }
  static void stable_three(Node node) { node.storage = 1; node.provenance = 1; }
  static void misses_provenance(Node node) { node.storage = 1; }
}
