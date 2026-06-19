class StateBranchChecker { boolean checked; void check(boolean admin, String name) { if (admin) { this.checked = true; } if (this.checked && name == "admin") { print("hello"); } } }
