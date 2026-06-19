class FlowExample {
  var status = 0
  var valid = false
  var done = false
  func prepare() { self.status = 1 }
  func validate() { self.valid = self.status == 1 }
  func commit() { self.done = self.valid }
  func ok1() { self.prepare(); self.validate(); self.commit() }
  func ok2() { self.prepare(); self.validate(); self.commit() }
  func ok3() { self.prepare(); self.validate(); self.commit() }
  func ok4() { self.prepare(); self.validate(); self.commit() }
  func drift() { self.validate(); self.prepare(); self.commit() }
}
