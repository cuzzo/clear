package main
type TemporalOrderExample struct { a int; b int }
func (self *TemporalOrderExample) One() { self.a = 1 }
func (self *TemporalOrderExample) Two() { self.a = 2; self.b = 3 }
func (self *TemporalOrderExample) Three() { self.b = 4 }
func (self *TemporalOrderExample) Reader() int { return self.a }
