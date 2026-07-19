import XCTest
@testable import Classifier

final class ClassifierTests: XCTestCase {
    func testSmoke() { XCTAssertTrue(true) }
    func testPositivePrimary() { XCTAssertEqual("positive", classify(5)) }
    func testPositiveDuplicate() { XCTAssertEqual("positive", classify(5)) }
    func testHigh() {
        XCTAssertEqual("high", classify(11))
        XCTAssertTrue(isHigh(11))
    }
    func testNonpositive() {
        XCTAssertEqual("nonpositive", classify(-1))
        XCTAssertTrue(isNonpositive(-1))
    }
}
