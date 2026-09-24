import XCTest

@testable import Pomo

final class UpdateAvailabilityTests: XCTestCase {
    func test_hidesWhenEitherRevisionIsMissing() {
        XCTAssertFalse(updateIsAvailable(installed: nil, remote: "abc"))
        XCTAssertFalse(updateIsAvailable(installed: "abc", remote: nil))
        XCTAssertFalse(updateIsAvailable(installed: "  ", remote: "abc"))
        XCTAssertFalse(updateIsAvailable(installed: "abc", remote: "\n"))
    }

    func test_hidesWhenRevisionsMatch() {
        XCTAssertFalse(updateIsAvailable(installed: "abc", remote: "abc"))
        XCTAssertFalse(updateIsAvailable(installed: " abc\n", remote: "abc"))
    }

    func test_showsWhenRevisionsDiffer() {
        XCTAssertTrue(updateIsAvailable(installed: "aaa", remote: "bbb"))
    }

    func test_updateCheckInterval_isOneHour() {
        XCTAssertEqual(UpdateCheck.interval, 60 * 60)
    }
}
