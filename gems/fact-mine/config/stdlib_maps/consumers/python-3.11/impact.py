from collections import OrderedDict


def move_last(values: OrderedDict[str, int]) -> None:
    values.move_to_end("key")
