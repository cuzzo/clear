export class JavaScriptSyntaxFactsCore {
  #status;

  constructor(status, sink) {
    this.#status = status;
    this.count = 0;
    this.sink = sink;
  }

  process(user, items, callback) {
    const name = user?.profile?.name;
    const account = { name, active: user.active };
    callback(account);

    switch (user.role) {
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

    if (this.#status === "idle" && user.ready) {
      this.count += 1;
      this.publish("busy");
    } else {
      console.warn("not ready");
    }

    for (const index in items) {
      this.#audit(items[index]);
    }

    return name ?? null;
  }

  #audit(name) {
    console.log(name);
    this.sink.send("record", name);
    const me = this;
    const processItem = ({ name, active }) => { console.log(name, active); };
    try {
      this.count += 1;
    } catch (e) {
      console.error(e);
    } finally {
      this.count = 0;
    }
    return this.#status;
  }

  ready() {
    return this.count > 0;
  }
}

export function normalizeValue(input, defaultValue = null, ...rest) {
  return input ?? defaultValue;
}

