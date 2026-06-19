struct Worker;

impl Worker {
    pub fn run(&self, items: Items) {
        self.prepare();
        if true {
            self.validate();
        }
        for item in items {
            self.helper(item);
        }
    }

    fn prepare(&self) {}
    fn ready(&self) -> bool { true }
    pub fn validate(&self) {}
    fn helper(&self, item: Item) { item; }
}
