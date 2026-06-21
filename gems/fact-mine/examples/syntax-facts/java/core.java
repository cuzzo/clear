package syntaxfacts;

class JavaSyntaxFactsCore {
  private Status status;
  private int count;

  public JavaSyntaxFactsCore(Status status) {
    this.status = status;
    this.count = 0;
  }

  public String process(User user, Iterable<Item> items, Callback callback) {
    String name = user.profile().name();
    Account account = new Account(name, user.active());
    callback.call(account);

    switch (user.role()) {
      case "owner":
      case "admin":
        this.escalate(user);
        break;
      case "guest":
        this.fallback(user);
        break;
      default:
        this.defaultCase(user);
    }

    if (this.status == Status.IDLE && user.ready()) {
      this.count += 1;
      this.publish(Status.BUSY);
    } else {
      System.err.println("not ready");
    }

    for (Item item : items) {
      item.children();
    }

    return name;
  }

  private void audit(String name) {
    System.out.println(name);
    this.send("record", name);
    this.status.name();
  }

  boolean ready() {
    return this.count > 0;
  }
}

