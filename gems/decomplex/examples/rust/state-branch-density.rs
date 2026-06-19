struct StateBranchChecker {
    checked: bool,
}

impl StateBranchChecker {
    fn check(&mut self, user: User) {
        if user.admin {
            self.checked = true;
        }

        if self.checked && user.name == "admin" {
            print("hello");
        }
    }
}
