<?php
class TemporalOrderExample {
  public function one() {
    $this->a = 1;
  }

  public function two() {
    $this->a = 2;
    $this->b = 3;
  }

  public function three() {
    $this->b = 4;
  }

  public function reader() {
    return $this->a;
  }
}
