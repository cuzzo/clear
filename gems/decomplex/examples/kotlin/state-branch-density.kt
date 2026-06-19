class StateBranchChecker { var checked = false; fun check(user: User) { if (user.admin) { this.checked = true } if (this.checked && user.name == "admin") { print("hello") } } }
