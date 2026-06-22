struct StateBranchChecker {
    checked: bool,
}

impl StateBranchChecker {
    fn check(&mut self, admin: bool, name: String) {
        if admin {
            self.checked = true;
        }

        if self.checked && name == "admin" {
            print("hello");
        }
    }
}
