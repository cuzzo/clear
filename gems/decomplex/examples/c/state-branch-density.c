typedef struct StateBranchChecker { int checked; } StateBranchChecker;
void check(StateBranchChecker *self, bool admin, const char *name) { if (admin) { self->checked = true; } if (self->checked && name == "admin") { print("hello"); } }
