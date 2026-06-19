class StateBranchChecker { bool checked; void check(User user) { if (user.admin) { this.checked = true; } if (this.checked && user.name == "admin") { print("hello"); } } }
