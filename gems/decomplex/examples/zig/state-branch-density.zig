const StateBranchChecker = struct {
    checked: bool,

    pub fn check(self: *StateBranchChecker, admin: bool, name: []const u8) void {
        if (admin) {
            self.checked = true;
        }

        if (self.checked and name == "admin") {
            print("hello");
        }
    }
};
