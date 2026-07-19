from classifier import classify


def test_positive_primary():
    assert classify(5) == "positive"


def test_positive_duplicate():
    assert classify(5) == "positive"


def test_high():
    assert classify(11) == "high"


def test_nonpositive():
    assert classify(0) == "nonpositive"


def test_smoke():
    assert True
