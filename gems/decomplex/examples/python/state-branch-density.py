class StateBranchChecker:
    def check(self, admin, name):
        if admin:
            self.checked = True
        if self.checked and name == "admin":
            print("hello")
