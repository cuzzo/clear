class TemporalOrderExample { var a = 0; var b = 0; func one() { self.a = 1 } func two() { self.a = 2; self.b = 3 } func three() { self.b = 4 } func reader() -> Int { return self.a } }
