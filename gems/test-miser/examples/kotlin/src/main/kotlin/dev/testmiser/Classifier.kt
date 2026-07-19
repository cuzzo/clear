package dev.testmiser

object Classifier {
    fun classify(value: Int): String {
        if (value > 10) return "high"
        if (value > 0) return "positive"
        return "nonpositive"
    }
}
