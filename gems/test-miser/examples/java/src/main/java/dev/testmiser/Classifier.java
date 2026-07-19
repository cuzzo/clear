package dev.testmiser;

public final class Classifier {
    private Classifier() {}

    public static String classify(int value) {
        if (value > 10) return "high";
        if (value > 0) return "positive";
        return "nonpositive";
    }
}
