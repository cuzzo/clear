class StateMeshExample {
  var a = 0
  var b = 0

  fun initialize() {
    this.a = 1
    this.b = 2
  }

  fun writer() {
    this.a = 3
  }

  fun reader(): Int {
    return this.a + this.b
  }

  fun a_alias(): Int {
    return this.a
  }
}
