typedef struct Worker { int ready_flag; } Worker;
void run(Worker *self, Items items) { prepare(self); if (ready(self)) { validate(self); } for (int item = 0; item < items.count; item++) { helper(self, item); } }
void prepare(Worker *self) {}
bool ready(Worker *self) { return true; }
void validate(Worker *self) {}
void helper(Worker *self, Item item) { item.use(); }
