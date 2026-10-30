import XCTest

/// Drives the real app. Each test starts it in a data folder of its own, so these never touch real settings or downloads.
final class VidFlowUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dataDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("VidFlowUITests-\(UUID().uuidString)")
        app = XCUIApplication()
        app.launchEnvironment = ["VIDFLOW_DATA_DIR": dataDir.path, "VIDFLOW_LANGUAGE": "en", "VIDFLOW_SKIP_FIRST_RUN": "1"]
    }

    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(at: dataDir)
    }

    private func title(_ text: String) -> XCUIElement { app.windows[text] }

    /// A bad state update at launch once made the app spin and crash before showing anything.
    func testLaunchesToANewDownloadAndStaysResponsive() {
        app.launch()
        XCTAssertTrue(title("New Download").waitForExistence(timeout: 15))
        XCTAssertTrue(app.textFields["Video link"].exists)
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.textFields["Video link"].isHittable)
    }

    func testSidebarReachesEveryPage() {
        app.launch()
        XCTAssertTrue(title("New Download").waitForExistence(timeout: 15))
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(title("Downloads").waitForExistence(timeout: 5))
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(title("Templates").waitForExistence(timeout: 5))
        app.buttons["Accounts"].click()
        XCTAssertTrue(title("Accounts").waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(title("New Download").waitForExistence(timeout: 5))
    }

    /// The sidebar list once jumped back to its first row whenever the window lost focus on the Accounts page.
    func testOpeningSettingsKeepsThePage() {
        app.launch()
        XCTAssertTrue(title("New Download").waitForExistence(timeout: 15))
        app.buttons["Accounts"].click()
        XCTAssertTrue(title("Accounts").waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        for tab in ["General", "Downloads", "Network", "Updates", "About"] {
            let button = app.toolbars.buttons[tab].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), tab)
            button.click()
        }
        XCTAssertTrue(title("Accounts").exists)
    }

    func testTypingALinkEnablesParse() {
        app.launch()
        let field = app.textFields["Video link"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        let parse = app.buttons["Parse"]
        XCTAssertFalse(parse.isEnabled)
        field.click()
        field.typeText("https://example.com/video")
        XCTAssertTrue(parse.isEnabled)
    }
}
