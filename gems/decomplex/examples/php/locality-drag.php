<?php
function run($user, $cart, $logger) {
  $receipt_id = $user->id;

  $total = $cart->total;
  if ($total > 100) {
    if ($cart->discountable()) {
      $discount = 10;
    }
  }
  if ($cart->taxable()) {
    if ($cart->region) {
      $tax = $total * 0.2;
    }
  }
  if ($logger->enabled()) {
    if ($logger->debug()) {
      $logger->info($total);
    }
  }
  if ($cart->valid()) {
    if ($cart->ready()) {
      $status = READY;
    }
  }

  emit($receipt_id);
}
