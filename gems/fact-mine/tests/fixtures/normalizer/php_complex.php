<?php
try {
    throw new Exception("Error");
} catch (Exception $e) {
    echo $e->getMessage();
} finally {
    echo "Done";
}

$a = $b ?: $c;
$d = $e ?? $f;

function foo() {
    yield 1;
}
