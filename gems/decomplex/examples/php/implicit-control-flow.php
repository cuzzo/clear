<?php
class FlowExample {
  public function prepare() { $this->status = READY; }
  public function validate() { $this->valid = $this->status == READY; }
  public function commit() { $this->done = $this->valid; }

  public function ok1() { $this->prepare(); $this->validate(); $this->commit(); }
  public function ok2() { $this->prepare(); $this->validate(); $this->commit(); }
  public function ok3() { $this->prepare(); $this->validate(); $this->commit(); }
  public function ok4() { $this->prepare(); $this->validate(); $this->commit(); }
  public function drift() { $this->validate(); $this->prepare(); $this->commit(); }
}
