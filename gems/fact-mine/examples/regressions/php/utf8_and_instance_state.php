<?php

class First {
    public function set($value) {
        if ($value) {
            if ($this->options) {
                $this->options = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa€Š";
            }
        }
    }

    public function get() { return $this->options; }
}

class Second {
    public function set($value) { $this->options = $value; }
    public function get() { return $this->options; }
}
