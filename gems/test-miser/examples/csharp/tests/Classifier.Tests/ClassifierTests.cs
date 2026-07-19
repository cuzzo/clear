using TestMiserExample;
using Xunit;

namespace TestMiserExample.Tests;

public class ClassifierTests
{
    [Fact] public void PositivePrimary() => Assert.Equal("positive", Classifier.Classify(5));
    [Fact] public void PositiveDuplicate() => Assert.Equal("positive", Classifier.Classify(5));
    [Fact] public void High() => Assert.Equal("high", Classifier.Classify(11));
    [Fact] public void Nonpositive() => Assert.Equal("nonpositive", Classifier.Classify(0));
    [Fact] public void Smoke() => Assert.True(true);
}
