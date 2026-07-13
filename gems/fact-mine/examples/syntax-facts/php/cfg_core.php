<?php

function choose(int $value): int
{
    if ($value > 0) {
        return $value;
    }
    return 0;
}
