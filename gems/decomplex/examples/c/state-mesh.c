typedef struct StateMeshExample { int a; int b; } StateMeshExample;
void initialize(StateMeshExample *self) { self->a = 1; self->b = 2; }
void writer(StateMeshExample *self) { self->a = 3; }
int reader(StateMeshExample *self) { return self->a + self->b; }
int a_alias(StateMeshExample *self) { return self->a; }
