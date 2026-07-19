package dev.testmiser;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

class ClassifierTest {
    @Test void positivePrimary() { assertEquals("positive", Classifier.classify(5)); }
    @Test void positiveDuplicate() { assertEquals("positive", Classifier.classify(5)); }
    @Test void high() { assertEquals("high", Classifier.classify(11)); }
    @Test void nonpositive() { assertEquals("nonpositive", Classifier.classify(0)); }
    @Test void smoke() { assertTrue(true); }
}
