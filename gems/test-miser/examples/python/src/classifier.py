def classify(value: int) -> str:
    if value > 10:
        return "high"
    if value > 0:
        return "positive"
    return "nonpositive"
