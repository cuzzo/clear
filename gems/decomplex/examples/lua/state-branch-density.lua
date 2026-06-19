StateBranchChecker = {}
function StateBranchChecker:check(user) if user.admin then self.checked = true end if self.checked and user.name == "admin" then print("hello") end end
