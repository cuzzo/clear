void handle(Node *self) {
  switch (self) {
  case AST_Call: self->line(); self->col(); self->ty(); self->span(); self->parent(); self->recv(); break;
  case AST_Func: self->line(); self->col(); self->ty(); self->span(); self->parent(); self->name(); break;
  case AST_Lit: self->line(); self->col(); self->ty(); self->span(); self->parent(); self->value(); break;
  }
}
