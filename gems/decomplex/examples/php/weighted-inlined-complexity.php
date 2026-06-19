<?php
class WeightedInlineExample {
  public function checkout($user, $cart) {
    $this->validate_user($user);
    $this->apply_discount($cart);
    $this->process_payment($user, $cart);
    $this->audit_cart($cart);
  }

  private function validate_user($user) {
    if (!$user) { return false; }
    if ($user->active() && !$user->suspended()) {
      if ($user->profile->complete()) { return true; }
      return false;
    }
    return false;
  }

  private function apply_discount($cart) {
    if ($cart->total > 100 && $this->eligible()) {
      if ($this->holiday()) { return 20; }
      if ($this->loyalty_month()) { return 15; }
      return 10;
    }
  }

  private function process_payment($user, $cart) {
    if ($this->gateway->ready()) {
      if ($cart->total > 0 && $user->active()) {
        if ($this->fraud_check($user)) { $this->charge($user, $cart); }
        else { $this->decline($user); }
      }
    }
  }

  private function audit_cart($cart) {
    foreach ($cart->items as $item) {
      if ($item->taxable()) {
        if ($item->region && $item->amount > 0) {
          $this->record_tax($item);
        }
      }
    }
  }
}
