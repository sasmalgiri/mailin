import XCTest
@testable import maxmailin

/// Trivial harness check: confirms the test target links against the maxmailin
/// module and RunSomeTests can execute it. Real verification lives in
/// V2VerificationTests.
final class SmokeTests: XCTestCase {
    func testHarnessRuns() {
        XCTAssertEqual(2 + 2, 4)
    }
}
