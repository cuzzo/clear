StateMeshExample = {}
function StateMeshExample:initialize() self.a = 1; self.b = 2 end
function StateMeshExample:writer() self.a = 3 end
function StateMeshExample:reader() return self.a + self.b end
function StateMeshExample:a_alias() return self.a end
