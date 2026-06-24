from __future__ import annotations

import os.path


class PythonSyntaxFactsCore:
    def __init__(self, lock, resource):
        self._lock = lock
        self.resource = resource
        self.count = 0

    def process(self, user: "User", items: list[str], callback):
        name: str = user.profile.name
        pending: str
        result = []
        marker = "\\n"

        with self._lock:
            self.count += 1

        with open(user.path) as handle:
            data = handle.read()

        for item in items:
            if item is None:
                continue

            if user.ready and item.startswith("x"):
                callback(item)

            match item:
                case "owner" | "admin":
                    self.escalate(user)
                case _:
                    self.default(user)

            result.append(item)

        index = 0
        while index < len(result):
            if result[index] == "stop":
                break

            try:
                self.audit(result[index])
            except ValueError:
                continue

            index += 1

        assert result
        return data if result else marker

    def _normalize(self, value: str | None = None):
        cleaned = value.strip() if value is not None else "missing"
        chained = "hello" "world"
        try:
            self.count += 1
        finally:
            pass
        return cleaned

    def generator(self, values):
        for value in values:
            yield value

    def simple_with(self, resource):
        with resource:
            pass

    def options(self, a, b=1, *args, c=2, **kwargs):
        try:
            return a + b
        finally:
            pass

