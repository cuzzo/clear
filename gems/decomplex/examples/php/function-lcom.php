<?php
function mixed($price, $tax, $logger) {
  $subtotal = $price + $tax;
  $total = $subtotal * 2;
  $rounded = $total->round();

  $timestamp = now();
  $buffer = Buffer::init();
  $buffer->push($timestamp);
  $logger->info($buffer);

  return Result::init($rounded, $buffer);
}
