package main
type StateBranchChecker struct { checked bool }
func (self *StateBranchChecker) check(user User) { if user.admin { self.checked = true } if self.checked && user.name == "admin" { print("hello") } }
