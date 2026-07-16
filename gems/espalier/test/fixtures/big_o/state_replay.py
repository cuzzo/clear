# parse_statement(n) = speculate(n) + parse_value(n)
# speculate(n) = parse_value(n) + O(1), and parse_value(n) = parse_statement(n - 1) + O(1).
# Therefore parse_statement(n) = 2 * parse_statement(n - 1) + O(1).
class PyReplayCursor:
    def __init__(self, tokens):
        self.tokens = tokens
        self.cursor = 0

    def parse_statement(self):
        self.speculate()
        self.parse_value()

    def speculate(self):
        checkpoint = self.cursor
        self.parse_value()
        self.cursor = checkpoint

    def parse_value(self):
        if self.cursor >= len(self.tokens):
            return

        self.tokens[self.cursor]
        self.cursor += 1
        self.parse_statement()
