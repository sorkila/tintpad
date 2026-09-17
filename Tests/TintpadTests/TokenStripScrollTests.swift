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
        XCTAssertFalse(PaletteView.stripIsScrolled(contentMinX: -0.4))
    }

    func testScrollingByTheLeadingPadIsAScroll() {
        // The old rest state: token 0 aligned to the edge, content moved by the pad.
        XCTAssertTrue(PaletteView.stripIsScrolled(contentMinX: -PaletteView.stripLeadingPad))
        XCTAssertTrue(PaletteView.stripIsScrolled(contentMinX: -120))
    }
}
