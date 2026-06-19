class StateBranchChecker { var checked = false; func check(user: User) { if user.admin { self.checked = true } if self.checked && user.name == "admin" { print("hello") } } }
