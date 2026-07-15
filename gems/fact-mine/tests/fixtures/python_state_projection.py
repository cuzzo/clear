class Cache:
    def __init__(self):
        self._items = {}
        self._record_buffer_lock = make_lock()

    def fetch(self, key, theme, element):
        with self._record_buffer_lock as lock, theme.guard:
            cached = self._items[key]
        return cached, theme.ansi_colors, element.href


class Console:
    def export(self, values):
        def make_tag(value):
            return value.tag
        return [make_tag(value) for value in values]
