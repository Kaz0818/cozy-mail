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
        // そのときは「ファイル > 新規ウィンドウ」(⌥⌘N) で開く (⌘N は「新規メッセージ」)
        if !app.windows.firstMatch.waitForExistence(timeout: 5) {
            app.typeKey("n", modifierFlags: [.command, .option])
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

    /// T16: 一覧で ↓ と J を押すと、次のメールが開く。
    @MainActor
    func testArrowKeysAndJMoveToTheNextMessage() throws {
        let app = launch()
        let row = findRow("preview-1", in: app)
        row.click()
        XCTAssertTrue(app.staticTexts["<s.yamada@example.com>"].waitForExistence(timeout: 5), "1 通目が開かない")

        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["<k.tanaka@example.com>"].waitForExistence(timeout: 5), "↓ で次のメールに移らない")

        app.typeKey("j", modifierFlags: [])
        XCTAssertTrue(app.staticTexts["<shopping@mail.yahoo.example>"].waitForExistence(timeout: 5), "J で次のメールに移らない")

        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["<k.tanaka@example.com>"].waitForExistence(timeout: 5), "↑ で前のメールに戻らない")
    }

    /// T16: メニューバーに「メッセージ」メニューがあり、操作が並んでいる。
    @MainActor
    func testMessageMenuListsTheActions() throws {
        let app = launch()
        _ = findRow("preview-1", in: app)
        let menu = app.menuBars.menuBarItems["メッセージ"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "「メッセージ」メニューがない")
        menu.click()
        for title in ["返信", "全員に返信", "転送", "アーカイブ (E)", "削除 (⌫)", "迷惑メールにする"] {
            XCTAssertTrue(app.menuItems[title].exists, "「\(title)」がない")
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    /// T18: ⌘N で作成ウィンドウが開き、⌘↩ で送る。見本のメールのときは、送ろうとするとアカウントの追加を案内する。
    @MainActor
    func testCommandNOpensANewMessageWindow() throws {
        let app = launch()
        _ = findRow("preview-1", in: app)
        app.typeKey("n", modifierFlags: .command)

        let to = app.textFields["compose.to"]
        XCTAssertTrue(to.waitForExistence(timeout: 5), "作成ウィンドウが開かない")
        to.click()
        to.typeText("k.tanaka@example.com")
        XCTAssertTrue(app.menuItems["送信"].exists, "メニューに「送信」がない")
        // ⌘↩ で送る (メニューの「メッセージ > 送信」)
        app.typeKey(.return, modifierFlags: .command)

        let error = app.descendants(matching: .any)["compose.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5), "送れないことが知らされない")
    }

    /// T18: メールを選んで ⌘R を押すと、件名に「Re: 」が付いた返信のウィンドウが開く。
    @MainActor
    func testCommandRRepliesToTheSelectedMessage() throws {
        let app = launch()
        findRow("preview-1", in: app).click()
        XCTAssertTrue(app.staticTexts["<s.yamada@example.com>"].waitForExistence(timeout: 5))
        app.typeKey("r", modifierFlags: .command)

        let subject = app.textFields["compose.subject"]
        XCTAssertTrue(subject.waitForExistence(timeout: 5), "返信のウィンドウが開かない")
        let filled = NSPredicate(format: "value == %@", "Re: 企画のご提案について")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: filled, object: subject)], timeout: 5), .completed,
                       "件名が「Re: 企画のご提案について」にならない: \(String(describing: subject.value))")
        XCTAssertEqual(app.textFields["compose.to"].value as? String, "山田 さくら <s.yamada@example.com>")
    }
}

