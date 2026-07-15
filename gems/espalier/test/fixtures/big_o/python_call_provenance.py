def helper(items):
    for item in items:
        consume(item)


def unrelated(left, right):
    for x in left:
        for y in right:
            consume(x, y)


def caller(items):
    helper(items)
