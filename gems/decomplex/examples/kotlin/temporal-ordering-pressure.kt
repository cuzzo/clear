class TemporalOrderExample {
  var a = 0
  var b = 0

  fun one() {
    this.a = 1
  }

  fun two() {
    this.a = 2
    this.b = 3
  }

  fun three() {
    this.b = 4
  }

  fun reader(): Int {
    return this.a
  }
}
