class StateBranchChecker { check(admin, name) { if (admin) { this.checked = true; } if (this.checked && name == "admin") { print("hello"); } } }
