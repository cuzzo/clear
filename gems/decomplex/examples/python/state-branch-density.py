class StateBranchChecker:
    def check(self, user):
        if user.admin:
            self.checked = True
        if self.checked and user.name == "admin":
            print("hello")
