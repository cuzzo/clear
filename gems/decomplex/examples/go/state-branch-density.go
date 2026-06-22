package main
type StateBranchChecker struct { checked bool }
func (self *StateBranchChecker) check(admin bool, name string) { if admin { self.checked = true } if self.checked && name == "admin" { print("hello") } }
