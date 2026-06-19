StateBranchChecker = {}
function StateBranchChecker:check(admin, name) if admin then self.checked = true end if self.checked and name == "admin" then print("hello") end end
