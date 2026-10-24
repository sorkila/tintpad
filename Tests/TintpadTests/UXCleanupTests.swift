import XCTest
@testable import Tintpad

/// House style for product copy: no em dashes, no prose semicolons.
private func assertHouseStyle(_ lines: [String], file: StaticString = #filePath, line: UInt = #line) {
    for text in lines {
        XCTAssertFalse(text.contains("—"), text, file: file, line: line)
        XCTAssertFalse(text.contains(";"), text, file: file, line: line)
    }
}

/// The app's own Swift sources, as (file name, code lines). Comment lines are
/// dropped, so a comment may name a color the code must not use.
private func sourceCodeLines() throws -> [(file: String, line: Int, text: String)] {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Tintpad")
    let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }
    XCTAssertFalse(files.isEmpty, "no sources found at \(sources.path)")
    var out: [(String, Int, String)] = []
    for url in files {
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        for (i, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            out.append((url.lastPathComponent, i + 1, line))
        }
    }
    return out
}

/// Black and white only, danger red the one color. A stray system color or
/// a second red is a design leak, caught here the way the em-dash tests
/// catch a voice leak. Content colors (repo hues, agent tints) are built
/// with `Color(hue:)` or from stored values, and stay allowed.
final class ColorLeakTests: XCTestCase {
    private static let named = "red|green|blue|orange|yellow|purple|pink|teal|mint|cyan|indigo|brown"

    func testNoSystemColorsOrAccentInProductSurfaces() throws {
        let patterns = [
            // `Color.green`, `NSColor.red`
            "\\b(Color|NSColor)\\.(\(Self.named))\\b",
            // `NSColor.systemGreen`
            "\\bNSColor\\.system(Red|Green|Blue|Orange|Yellow|Purple|Pink|Teal|Mint|Cyan|Indigo|Brown)\\b",
            // `.foregroundStyle(.green)`, `.tint(.red)`, `.fill(.orange)`
            "\\b(foregroundStyle|foregroundColor|tint|fill|stroke|strokeBorder|background)\\(\\s*\\.(\(Self.named))\\b",
            // The system accent is the user's color, never ours.
            "\\.accentColor\\b",
        ].map { try! NSRegularExpression(pattern: $0) }
        for (file, line, text) in try sourceCodeLines() {
            let range = NSRange(text.startIndex..., in: text)
            for p in patterns where p.firstMatch(in: text, range: range) != nil {
                XCTFail("\(file):\(line) leaks a color: \(text.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    /// One red: `dangerTint` in Models.swift is the only literal RGB color.
    func testDangerTintIsTheOnlyRGBLiteral() throws {
        let literal = try NSRegularExpression(pattern: "\\b(Color|NSColor)\\((red|srgbRed|calibratedRed|deviceRed):")
        for (file, line, text) in try sourceCodeLines() where file != "Models.swift" {
            if literal.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                XCTFail("\(file):\(line) defines its own color, use dangerTint or ink: \(text)")
            }
        }
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
