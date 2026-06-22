<?php
function frame_pred($node) { return $node->provenance == FRAME; }
function is_frame($node) { return $node->provenance == FRAME; }
function heap_pred($node) { return $node->provenance == HEAP; }

function somewhere($node) {
  if ($node->provenance == FRAME) { return 1; }
}
