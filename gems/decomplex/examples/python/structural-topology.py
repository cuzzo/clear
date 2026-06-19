class Worker:
    def run(self, items):
        self.prepare()
        if self.ready():
            self.validate()
        for item in items:
            self.helper(item)
    def prepare(self): pass
    def ready(self): return True
    def validate(self): pass
    def helper(self, item): return item
