class FlowExample {
  var status = 0
  var valid = false
  var done = false
  fun prepare() { this.status = 1 }
  fun validate() { this.valid = this.status == 1 }
  fun commit() { this.done = this.valid }
  fun ok1() { this.prepare(); this.validate(); this.commit() }
  fun ok2() { this.prepare(); this.validate(); this.commit() }
  fun ok3() { this.prepare(); this.validate(); this.commit() }
  fun ok4() { this.prepare(); this.validate(); this.commit() }
  fun drift() { this.validate(); this.prepare(); this.commit() }
}
