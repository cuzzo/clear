<?php

declare(strict_types=1);

namespace TestMiserExample\Tests;

use PHPUnit\Framework\TestCase;
use TestMiserExample\Classifier;

final class ClassifierTest extends TestCase
{
    public function testSmoke(): void
    {
        self::assertTrue(true);
    }

    public function testPositivePrimary(): void
    {
        self::assertSame('positive', Classifier::classify(5));
    }

    public function testPositiveDuplicate(): void
    {
        self::assertSame('positive', Classifier::classify(5));
    }

    public function testHigh(): void
    {
        self::assertSame('high', Classifier::classify(11));
    }

    public function testNonpositive(): void
    {
        self::assertSame('nonpositive', Classifier::classify(0));
    }
}
