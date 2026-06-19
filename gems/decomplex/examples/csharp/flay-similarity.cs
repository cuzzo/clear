class Example {
  static int first_clone(Node node) {
    var total = 0;
    var value1 = node.part1;
    if (value1.ready() && value1.enabled()) {
      total += value1.amount;
    }
    var value2 = node.part2;
    if (value2.ready() && value2.enabled()) {
      total += value2.amount;
    }
    var value3 = node.part3;
    if (value3.ready() && value3.enabled()) {
      total += value3.amount;
    }
    var value4 = node.part4;
    if (value4.ready() && value4.enabled()) {
      total += value4.amount;
    }
    var value5 = node.part5;
    if (value5.ready() && value5.enabled()) {
      total += value5.amount;
    }
    var value6 = node.part6;
    if (value6.ready() && value6.enabled()) {
      total += value6.amount;
    }
    var value7 = node.part7;
    if (value7.ready() && value7.enabled()) {
      total += value7.amount;
    }
    var value8 = node.part8;
    if (value8.ready() && value8.enabled()) {
      total += value8.amount;
    }
    return total;
  }

  static int second_clone(Node entry) {
    var total = 0;
    var item1 = entry.part1;
    if (item1.ready() && item1.enabled()) {
      total += item1.amount;
    }
    var item2 = entry.part2;
    if (item2.ready() && item2.enabled()) {
      total += item2.amount;
    }
    var item3 = entry.part3;
    if (item3.ready() && item3.enabled()) {
      total += item3.amount;
    }
    var item4 = entry.part4;
    if (item4.ready() && item4.enabled()) {
      total += item4.amount;
    }
    var item5 = entry.part5;
    if (item5.ready() && item5.enabled()) {
      total += item5.amount;
    }
    var item6 = entry.part6;
    if (item6.ready() && item6.enabled()) {
      total += item6.amount;
    }
    var item7 = entry.part7;
    if (item7.ready() && item7.enabled()) {
      total += item7.amount;
    }
    var item8 = entry.part8;
    if (item8.ready() && item8.enabled()) {
      total += item8.amount;
    }
    return total;
  }
}
