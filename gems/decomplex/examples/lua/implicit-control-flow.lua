FlowExample = {}
function FlowExample:prepare() self.status = 1 end
function FlowExample:validate() self.valid = self.status == 1 end
function FlowExample:commit() self.done = self.valid end
function FlowExample:ok1() self.prepare(); self.validate(); self.commit() end
function FlowExample:ok2() self.prepare(); self.validate(); self.commit() end
function FlowExample:ok3() self.prepare(); self.validate(); self.commit() end
function FlowExample:ok4() self.prepare(); self.validate(); self.commit() end
function FlowExample:drift() self.validate(); self.prepare(); self.commit() end
