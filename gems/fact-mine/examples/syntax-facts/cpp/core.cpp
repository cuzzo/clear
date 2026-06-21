#include <string>
#include <vector>

enum class Status {
  Idle,
  Busy
};

class CppSyntaxFactsCore {
  Status status;
  int count;
  Sink *sink;

public:
  explicit CppSyntaxFactsCore(Status status, Sink *sink)
      : status(status), count(0), sink(sink) {}

  std::string process(User &user, std::vector<Item> &items, Callback callback) {
    std::string name = user.profile().name();
    Account account{name, user.active()};
    callback(account);

    switch (user.role()) {
    case Role::Owner:
    case Role::Admin:
      escalate(user);
      break;
    case Role::Guest:
      fallback(user);
      break;
    default:
      defaultCase(user);
      break;
    }

    if (status == Status::Idle && user.ready()) {
      count += 1;
      publish(Status::Busy);
    } else {
      warn("not ready");
    }

    for (auto &item : items) {
      item.children();
    }

    return name;
  }

private:
  Status audit(const std::string &name) {
    std::cout << name;
    sink->send("record", name);
    return status;
  }

  bool ready() const {
    return count > 0;
  }
};

