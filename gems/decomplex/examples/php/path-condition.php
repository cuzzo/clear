<?php
function one($x, $y, $z) {
  if ($x->p() && $y->q() && $z->r()) { go($x); }
}

function two($x, $y, $z) {
  if ($x->p() && $y->q() && $z->r()) { go($x); }
}

function three($x, $y, $z) {
  if ($x->p() && $y->q() && $z->r()) { go($x); }
}

function bug($x, $y, $z) {
  if ($x->p() && $y->q()) { go($x); }
}
