public func classify(_ value: Int) -> String {
    if value > 10 { return "high" }
    if value > 0 { return "positive" }
    return "nonpositive"
}

public func isHigh(_ value: Int) -> Bool { value > 10 }
public func isNonpositive(_ value: Int) -> Bool { value <= 0 }
