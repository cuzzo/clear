package main
type StateMeshExample struct { a int; b int }
func (self *StateMeshExample) initialize() { self.a = 1; self.b = 2 }
func (self *StateMeshExample) writer() { self.a = 3 }
func (self *StateMeshExample) reader() int { return self.a + self.b }
func (self *StateMeshExample) a_alias() int { return self.a }
