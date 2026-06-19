class StateBranchChecker {
  var checked = false

  func check(admin: Bool, name: String) {
    if admin {
      self.checked = true
    }

    if self.checked && name == "admin" {
      print("hello")
    }
  }
}
