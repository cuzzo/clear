class StateBranchChecker {
  var checked = false

  fun check(admin: Boolean, name: String) {
    if (admin) {
      this.checked = true
    }

    if (this.checked && name == "admin") {
      print("hello")
    }
  }
}
