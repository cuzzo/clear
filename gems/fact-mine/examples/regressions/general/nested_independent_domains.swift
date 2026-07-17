struct Matrix {
  func fill(target: String) -> Int {
    let rows = self.count
    let columns = target.count
    var result = 0
    for row in 0..<rows {
      for column in 0..<columns {
        result += row + column
      }
    }
    return result
  }
}
