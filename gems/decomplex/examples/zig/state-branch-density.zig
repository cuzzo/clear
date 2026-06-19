const StateBranchChecker = struct {
    checked: bool,

    pub fn check(self: *StateBranchChecker, user: User) void {
        if (user.admin) {
            self.checked = true;
        }

        if (self.checked and user.name == "admin") {
            print("hello");
        }
    }
};
