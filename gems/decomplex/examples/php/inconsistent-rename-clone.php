<?php
function original() {
  $src = fetch(1);
  check($src);
  store($src);
  finalize($src);
}

function pasted() {
  $dst = fetch(2);
  check($dst);
  store($src);
  finalize($dst);
}
