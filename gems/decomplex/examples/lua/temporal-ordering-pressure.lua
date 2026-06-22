TemporalOrderExample = {}
function TemporalOrderExample:one() self.a = 1 end
function TemporalOrderExample:two() self.a = 2; self.b = 3 end
function TemporalOrderExample:three() self.b = 4 end
function TemporalOrderExample:reader() return self.a end
