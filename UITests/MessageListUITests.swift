import XCTest

/// 一覧の操作を、実際にアプリを起動して確かめる。
final class MessageListUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // 見本のメールで、前回のウィンドウ状態を使わずに起動する
        app.launchArguments += ["-ui-testing", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        return app
    }

    /// 2026-11-13 オーナーの報告: 行を右クリックしても、メニューが出ない。
    @MainActor
    func testRightClickingARowShowsTheActionsMenu() throws {
        let app = launch()
        let row = app.descendants(matching: .any)["messageRow.preview-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "一覧の行が見つからない")

        row.rightClick()

        XCTAssertTrue(app.menuItems["アーカイブ"].waitForExistence(timeout: 5), "右クリックのメニューが出ない")
        XCTAssertTrue(app.menuItems["削除"].exists)
        XCTAssertTrue(app.menuItems["迷惑メールにする"].exists)
    }

    @MainActor
    func testClickingARowSelectsIt() throws {
        let app = launch()
        let row = app.descendants(matching: .any)["messageRow.preview-3"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))

        row.click()

        // 差出人のアドレスは、右の本文の欄にだけ出る (一覧には出ない)
        XCTAssertTrue(app.staticTexts["<k.tanaka@example.com>"].waitForExistence(timeout: 5), "クリックしたメールが開かない")
    }
}
