typedef struct TemporalOrderExample { int a; int b; } TemporalOrderExample;
void one(TemporalOrderExample *self) { self->a = 1; }
void two(TemporalOrderExample *self) { self->a = 2; self->b = 3; }
void three(TemporalOrderExample *self) { self->b = 4; }
int reader(TemporalOrderExample *self) { return self->a; }
