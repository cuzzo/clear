pub fn check(self: *Self) void {
    self.cached = self.source + 1;
    self.source = 2;
    print(self.cached);
}
