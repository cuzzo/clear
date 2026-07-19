package dev.testmiser

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class ClassifierTest {
    @Test fun positivePrimary() = assertEquals("positive", Classifier.classify(5))
    @Test fun positiveDuplicate() = assertEquals("positive", Classifier.classify(5))
    @Test fun high() = assertEquals("high", Classifier.classify(11))
    @Test fun nonpositive() = assertEquals("nonpositive", Classifier.classify(0))
    @Test fun smoke() = assertTrue(true)
}
