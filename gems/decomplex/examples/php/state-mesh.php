<?php
class StateMeshExample {
  public function __construct() {
    $this->a = 1;
    $this->b = 2;
  }

  public function writer() {
    $this->a = 3;
  }

  public function reader() {
    return $this->a + $this->b;
  }

  public function a_alias() {
    return $this->a;
  }
}
