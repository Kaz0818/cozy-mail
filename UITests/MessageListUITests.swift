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
        // CI の Mac では、起動してもウィンドウが開かないことがある (2026-11-13 の CI で確認)。
        // そのときは「ファイル > 新規ウィンドウ」(⌘N) で開く
        if !app.windows.firstMatch.waitForExistence(timeout: 5) {
            app.typeKey("n", modifierFlags: .command)
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "ウィンドウが開かない")
        }
        return app
    }

    /// 行が見つからないときは、画面の部品の一覧をログに出す (CI で原因を追えるように)。
    @MainActor
    private func findRow(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let row = app.descendants(matching: .any)["messageRow.\(id)"]
        if !row.waitForExistence(timeout: 15) {
            print("---- 画面の部品 ----\n\(app.debugDescription)\n---- ここまで ----")
            XCTFail("一覧の行 \(id) が見つからない")
        }
        return row
    }

    /// 2026-11-13 オーナーの報告: 行を右クリックしても、メニューが出ない。
    @MainActor
    func testRightClickingARowShowsTheActionsMenu() throws {
        let app = launch()
        let row = findRow("preview-1", in: app)

        row.rightClick()

        XCTAssertTrue(app.menuItems["アーカイブ"].waitForExistence(timeout: 5), "右クリックのメニューが出ない")
        XCTAssertTrue(app.menuItems["削除"].exists)
        XCTAssertTrue(app.menuItems["迷惑メールにする"].exists)
    }

    @MainActor
    func testClickingARowSelectsIt() throws {
        let app = launch()
        let row = findRow("preview-3", in: app)

        row.click()

        // 差出人のアドレスは、右の本文の欄にだけ出る (一覧には出ない)
        XCTAssertTrue(app.staticTexts["<k.tanaka@example.com>"].waitForExistence(timeout: 5), "クリックしたメールが開かない")
    }
}
