import XCTest
import SwiftUI
@testable import Tintpad

final class TokenStripScrollTests: XCTestCase {
    func testIndexZeroTargetsTheStripStartNotTheToken() {
        XCTAssertTrue(PaletteView.scrollsToStripStart(0))
        XCTAssertFalse(PaletteView.scrollsToStripStart(1))
        XCTAssertFalse(PaletteView.scrollsToStripStart(7))
    }

    func testOtherIndicesKeepCenterAnchoring() {
        XCTAssertEqual(PaletteView.anchor(for: 0), .leading)
        XCTAssertEqual(PaletteView.anchor(for: 3), .center)
    }

    func testRestingStripIsNotScrolled() {
        XCTAssertFalse(PaletteView.stripIsScrolled(contentMinX: 0))
        // The live resting drift, measured on screen while the drop settles.
        XCTAssertFalse(PaletteView.stripIsScrolled(contentMinX: -1.5))
        XCTAssertFalse(PaletteView.stripIsScrolled(contentMinX: -PaletteView.stripLeadingPad))
    }

    func testARealScrollIsAScroll() {
        XCTAssertTrue(PaletteView.stripIsScrolled(contentMinX: -(PaletteView.stripScrollThreshold + 1)))
        XCTAssertTrue(PaletteView.stripIsScrolled(contentMinX: -120))
    }
}
