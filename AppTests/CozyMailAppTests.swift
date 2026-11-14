import Foundation
import Testing
@testable import CozyMail

@Test func appModuleIsLinked() {
    #expect(Bool(true))
}

/// 自動テストのときは、本物のアカウント・キーチェーン・保存ファイルに触れない (CLAUDE.md「絶対にやらない」)。
@Suite struct LaunchModeTests {
    /// この単体テストも、アプリを起動してその中で動いている。そのアプリが自動テストだと分かっていること。
    @Test func theAppHostingTheseTestsKnowsItIsUnderTest() {
        #expect(CozyMailApp.isAutomatedTest(ProcessInfo.processInfo))
    }

    @Test func uiTestsAreRecognisedByTheirLaunchArgument() {
        #expect(CozyMailApp.isAutomatedTest(arguments: ["Cozy Mail", "-ui-testing"], environment: [:]))
    }

    @Test func unitTestsAreRecognisedByXCTestsEnvironment() {
        #expect(CozyMailApp.isAutomatedTest(arguments: ["Cozy Mail"], environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
    }

    @Test func aNormalLaunchIsNotATest() {
        #expect(!CozyMailApp.isAutomatedTest(arguments: ["Cozy Mail", "-NSDocumentRevisionsDebugMode", "YES"], environment: ["HOME": "/Users/me"]))
    }
}
