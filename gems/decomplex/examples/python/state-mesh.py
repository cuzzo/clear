class StateMeshExample:
    def initialize(self):
        self.a = 1
        self.b = 2
    def writer(self):
        self.a = 3
    def reader(self):
        return self.a + self.b
    def a_alias(self):
        return self.a
