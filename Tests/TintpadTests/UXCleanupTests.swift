import XCTest
@testable import Tintpad

/// House style for product copy: no em dashes, no prose semicolons.
private func assertHouseStyle(_ lines: [String], file: StaticString = #filePath, line: UInt = #line) {
    for text in lines {
        XCTAssertFalse(text.contains("—"), text, file: file, line: line)
        XCTAssertFalse(text.contains(";"), text, file: file, line: line)
    }
}

/// An available update, said once in the menu and once in About.
final class UpdateCopyTests: XCTestCase {
    func testMenuNamesThePendingVersion() {
        XCTAssertEqual(UpdateCopy.menuTitle(pending: "0.4.2"), "Update to 0.4.2…")
        XCTAssertEqual(UpdateCopy.menuTitle(pending: nil), "Check for Updates…")
    }

    func testAboutButtonInstallsThePendingVersion() {
        XCTAssertEqual(UpdateCopy.buttonTitle(pending: "0.4.2"), "Install 0.4.2…")
        XCTAssertEqual(UpdateCopy.buttonTitle(pending: nil), "Check for Updates…")
    }

    func testUpdateCopyHouseStyle() {
        assertHouseStyle([
            UpdateCopy.menuTitle(pending: "0.4.2"), UpdateCopy.menuTitle(pending: nil),
            UpdateCopy.buttonTitle(pending: "0.4.2"), UpdateCopy.buttonTitle(pending: nil),
        ])
    }
}
