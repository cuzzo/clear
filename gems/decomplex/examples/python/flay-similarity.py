def first_clone(node):
    total = 0
    value1 = node.part1
    if value1.ready() and value1.enabled():
        total += value1.amount
    value2 = node.part2
    if value2.ready() and value2.enabled():
        total += value2.amount
    value3 = node.part3
    if value3.ready() and value3.enabled():
        total += value3.amount
    value4 = node.part4
    if value4.ready() and value4.enabled():
        total += value4.amount
    value5 = node.part5
    if value5.ready() and value5.enabled():
        total += value5.amount
    value6 = node.part6
    if value6.ready() and value6.enabled():
        total += value6.amount
    value7 = node.part7
    if value7.ready() and value7.enabled():
        total += value7.amount
    value8 = node.part8
    if value8.ready() and value8.enabled():
        total += value8.amount
    return total

def second_clone(entry):
    total = 0
    item1 = entry.part1
    if item1.ready() and item1.enabled():
        total += item1.amount
    item2 = entry.part2
    if item2.ready() and item2.enabled():
        total += item2.amount
    item3 = entry.part3
    if item3.ready() and item3.enabled():
        total += item3.amount
    item4 = entry.part4
    if item4.ready() and item4.enabled():
        total += item4.amount
    item5 = entry.part5
    if item5.ready() and item5.enabled():
        total += item5.amount
    item6 = entry.part6
    if item6.ready() and item6.enabled():
        total += item6.amount
    item7 = entry.part7
    if item7.ready() and item7.enabled():
        total += item7.amount
    item8 = entry.part8
    if item8.ready() and item8.enabled():
        total += item8.amount
    return total
