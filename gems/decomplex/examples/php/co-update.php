<?php
function stable_one($node) {
  $node->storage = HEAP;
  $node->provenance = HEAP;
}

function stable_two($node) {
  $node->storage = HEAP;
  $node->provenance = HEAP;
}

function stable_three($node) {
  $node->storage = HEAP;
  $node->provenance = HEAP;
}

function misses_provenance($node) {
  $node->storage = HEAP;
}
