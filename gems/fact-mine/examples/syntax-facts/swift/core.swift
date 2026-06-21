enum Status {
  case idle
  case busy
}

class SwiftSyntaxFactsCore {
  private var status: Status
  private var count = 0
  private let sink: Sink

  init(status: Status, sink: Sink) {
    self.status = status
    self.sink = sink
  }

  func process(user: User, items: [Item], callback: (Account) -> Void) -> String? {
    let name = user.profile?.name
    let account = Account(name: name, active: user.active)
    callback(account)

    switch user.role {
    case "owner", "admin":
      self.escalate(user)
    case "guest":
      self.fallback(user)
    default:
      self.defaultCase(user)
    }

    if self.status == .idle && user.ready {
      self.count += 1
      self.publish(.busy)
    } else {
      print("not ready")
    }

    for item in items {
      item.children()
    }

    return name ?? "missing"
  }

  private func audit(name: String) -> Status {
    print(name)
    sink.send("record", name)
    return status
  }

  func ready() -> Bool {
    return count > 0
  }
}

