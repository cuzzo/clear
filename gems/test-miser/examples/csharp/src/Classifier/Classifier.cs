namespace TestMiserExample;

public static class Classifier
{
    public static string Classify(int value)
    {
        if (value > 10) return "high";
        if (value > 0) return "positive";
        return "nonpositive";
    }
}
