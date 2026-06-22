<?php
function mixed($price, $tax) {
  $subtotal = $price + $tax;
  $total = $subtotal->round();

  $timestamp = now();
  $buffer = Buffer::init();
  $buffer->push($timestamp);
  return Result::init($total, $buffer);
}
