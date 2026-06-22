package main
type FlowExample struct { status int; valid bool; done bool }
func (self *FlowExample) prepare() { self.status = 1 }
func (self *FlowExample) validate() { self.valid = self.status == 1 }
func (self *FlowExample) commit() { self.done = self.valid }
func (self *FlowExample) ok1() { self.prepare(); self.validate(); self.commit() }
func (self *FlowExample) ok2() { self.prepare(); self.validate(); self.commit() }
func (self *FlowExample) ok3() { self.prepare(); self.validate(); self.commit() }
func (self *FlowExample) ok4() { self.prepare(); self.validate(); self.commit() }
func (self *FlowExample) drift() { self.validate(); self.prepare(); self.commit() }
