package main
type Worker struct {}
func (self *Worker) run(items Items) { self.prepare(); if self.ready() { self.validate() }; for _, item := range items { self.helper(item) } }
func (self *Worker) prepare() {}
func (self *Worker) ready() bool { return true }
func (self *Worker) validate() {}
func (self *Worker) helper(item Item) { item.use() }
