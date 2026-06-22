typedef struct FlowExample { int status; int valid; int done; } FlowExample;
void prepare(FlowExample *self) { self->status = 1; }
void validate(FlowExample *self) { self->valid = self->status == 1; }
void commit(FlowExample *self) { self->done = self->valid; }
void ok1(FlowExample *self) { prepare(self); validate(self); commit(self); }
void ok2(FlowExample *self) { prepare(self); validate(self); commit(self); }
void ok3(FlowExample *self) { prepare(self); validate(self); commit(self); }
void ok4(FlowExample *self) { prepare(self); validate(self); commit(self); }
void drift(FlowExample *self) { validate(self); prepare(self); commit(self); }
