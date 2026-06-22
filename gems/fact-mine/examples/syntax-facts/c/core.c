typedef enum {
  STATUS_IDLE,
  STATUS_BUSY
} Status;

typedef struct CSyntaxFactsCore {
  Status status;
  int count;
  Sink *sink;
} CSyntaxFactsCore;

void CSyntaxFactsCore_process(CSyntaxFactsCore *self, User *user, Item **items, int item_count, Callback callback) {
  const char *name = user->profile->name;
  Account account = make_account(name, user->active);
  callback(&account);

  switch (user->role) {
    case ROLE_OWNER:
    case ROLE_ADMIN:
      escalate(self, user);
      break;
    case ROLE_GUEST:
      fallback(self, user);
      break;
    default:
      default_case(self, user);
      break;
  }

  if (self->status == STATUS_IDLE && user->ready) {
    self->count += 1;
    publish(self, STATUS_BUSY);
  } else {
    warn("not ready");
  }

  for (int i = 0; i < item_count; i++) {
    item_children(items[i]);
  }
}

static Status CSyntaxFactsCore_audit(CSyntaxFactsCore *self, const char *name) {
  puts(name);
  sink_send(self->sink, "record", name);
  return self->status;
}

int CSyntaxFactsCore_ready(CSyntaxFactsCore *self) {
  return self->count > 0;
}

