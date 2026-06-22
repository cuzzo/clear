class StateBranchChecker { check(admin: boolean, name: string) { if (admin) { this.checked = true; } if (this.checked && name == "admin") { print("hello"); } } }
