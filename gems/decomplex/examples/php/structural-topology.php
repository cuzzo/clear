<?php
class Worker {
  public function run($items) {
    $this->prepare();
    if ($this->ready()) {
      $this->validate();
    }
    foreach ($items as $item) {
      $this->helper($item);
    }
  }

  private function prepare() {}
  private function ready() { return true; }
  public function validate() {}
  private function helper($item) { return $item; }
}
