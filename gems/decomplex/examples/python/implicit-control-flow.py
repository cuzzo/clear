class FlowExample:
    def prepare(self): self.status = 1
    def validate(self): self.valid = self.status == 1
    def commit(self): self.done = self.valid
    def ok1(self): self.prepare(); self.validate(); self.commit()
    def ok2(self): self.prepare(); self.validate(); self.commit()
    def ok3(self): self.prepare(); self.validate(); self.commit()
    def ok4(self): self.prepare(); self.validate(); self.commit()
    def drift(self): self.validate(); self.prepare(); self.commit()
