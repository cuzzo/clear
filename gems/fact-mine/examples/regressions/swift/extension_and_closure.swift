struct Counter {
  let values: [Int]
}

extension Counter {
  func incremented() -> [Int] {
    values.map { $0 + 1 }
  }

  func hasPositiveValue() -> Bool {
    values.contains(where: { $0 > 0 })
  }
}
