class ThemeContext:
    def __init__(self, inherit, items, record_buffer_lock):
        self.inherit = inherit
        self._items = items
        self._record_buffer_lock = record_buffer_lock

    def fetch(self, key, theme, element):
        with self._record_buffer_lock:
            cached = self._items[key]
        return cached, theme.ansi_colors, element.href

    def __enter__(self):
        push_theme()


class Console:
    def export(self, values):
        def make_tag(value):
            return value.tag
        return [make_tag(value) for value in values]
