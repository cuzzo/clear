class TemporalOrderExample:
    def one(self): self.a = 1
    def two(self): self.a = 2; self.b = 3
    def three(self): self.b = 4
    def reader(self): return self.a
