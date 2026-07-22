import sys

sys.path.insert(0, "lib")
from calculator import value

if value() != "new":
    raise AssertionError("Failure: expected new behavior")
