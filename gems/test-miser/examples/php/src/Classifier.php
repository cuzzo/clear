<?php

declare(strict_types=1);

namespace TestMiserExample;

final class Classifier
{
    public static function classify(int $value): string
    {
        if ($value > 10) {
            return 'high';
        }

        if ($value > 0) {
            return 'positive';
        }

        return 'nonpositive';
    }
}
