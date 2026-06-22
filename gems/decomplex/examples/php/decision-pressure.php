<?php
function scan($node) {
  $value = $node->symbol;
  return $value->isNull();
}
