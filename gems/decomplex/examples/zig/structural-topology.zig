const Worker = struct {
    pub fn run(self: *Worker, items: Items) void {
        self.prepare();
        if (true) {
            self.validate();
        }
        for (items) |item| {
            self.helper(item);
        }
    }

    fn prepare(self: *Worker) void { _ = self; }
    fn ready(self: *Worker) bool { _ = self; return true; }
    pub fn validate(self: *Worker) void { _ = self; }
    fn helper(self: *Worker, item: Item) void { _ = self; _ = item; }
};
