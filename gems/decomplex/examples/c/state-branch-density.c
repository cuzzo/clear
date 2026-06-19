typedef struct StateBranchChecker { int checked; } StateBranchChecker;
void check(StateBranchChecker *self, User user) { if (user.admin) { self->checked = true; } if (self->checked && user.name == "admin") { print("hello"); } }
