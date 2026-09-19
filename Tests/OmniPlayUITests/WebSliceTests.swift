import XCTest

/// The first vertical slice on the simulator: import → play → storage write → leave → relaunch → play again →
/// leave → the persisted web storage shows up under the game's saves. Uses the synthetic HTML5 fixture, which
/// counts its runs in localStorage; real MV/MZ boot markers need the private engine fixtures and run on device.
final class WebSliceTests: XCTestCase {
    private static var fixture: String {
        // Tests/OmniPlayUITests/WebSliceTests.swift → repository root → Fixtures/synthetic/html5-generic
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/synthetic/html5-generic").path(percentEncoded: false)
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// Plays until the pause button is up, then leaves through the menu.
    private func playAndLeave(_ app: XCUIApplication) {
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 30), "pause button did not appear; the game did not start")
        sleep(2) // let the page run its first frame and write storage
        pause.tap()
        let leave = app.buttons["Leave game"]
        XCTAssertTrue(leave.waitForExistence(timeout: 10))
        leave.tap()
        let confirm = app.buttons["Leave"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        XCTAssertTrue(app.buttons["Saves and backups"].firstMatch.waitForExistence(timeout: 15), "did not return to the game detail")
    }

    func testImportPlaySaveRelaunchContinue() {
        var app = launch(["--import", Self.fixture, "--play-first-game"])
        playAndLeave(app)
        app.terminate()

        app = launch(["--play-first-game"])
        playAndLeave(app)

        app.buttons["Saves and backups"].firstMatch.tap()
        let store = app.descendants(matching: .any)["persistentStore.webLocalStorage"].firstMatch
        XCTAssertTrue(store.waitForExistence(timeout: 10), "web storage store row missing")
        XCTAssertTrue(store.label.contains("1 file"), "expected the runs counter file, got: \(store.label)")
    }
}
