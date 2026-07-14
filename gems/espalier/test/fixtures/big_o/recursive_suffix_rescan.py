class PyRecursiveSuffixRescan:
    def __init__(self, items):
        self.items = items
        self.position = 0

    def walk(self):
        if self.position >= len(self.items):
            return

        self.scan_remaining()
        self.position += 1
        self.walk()

    def scan_remaining(self):
        cursor = self.position
        while cursor < len(self.items):
            consume(self.items[cursor])
            cursor += 1
