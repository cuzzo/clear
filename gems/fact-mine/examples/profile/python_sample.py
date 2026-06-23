# python_sample.py

class Database:
    def __init__(self):
        self.port: int = 5432

class Greeter:
    def __init__(self, db: Database):
        self._db = db

    def hello(self, name: str) -> str:
        return f"Hello {name}"
