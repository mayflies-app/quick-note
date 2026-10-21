import XCTest
@testable import QuickNoteCore

final class AppLanguageTests: XCTestCase {
    func testFirstSupportedSystemPreferenceWinsAndUnknownFallsBackToEnglish() {
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: ["fr-FR", "en-GB", "zh-Hans"]), .english)
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: ["ja-JP", "zh-Hant-TW", "en-US"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: ["de-DE"]), .english)
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: []), .english)
        XCTAssertEqual(AppLanguage.simplifiedChinese.rawValue, "zh-Hans")
        XCTAssertEqual(AppLanguage.english.title, "English")
        XCTAssertEqual(AppLanguage.simplifiedChinese.title, "简体中文")
    }

    func testResourceCatalogsHaveMatchingKeysAndFormatArguments() {
        let english = AppLanguage.english.catalog
        let chinese = AppLanguage.simplifiedChinese.catalog
        XCTAssertFalse(english.isEmpty, "SwiftPM must supply the actual localization resource bundle")
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        let pattern = try! NSRegularExpression(pattern: "%\\d*\\$?[@dfius]|%lld")
        func placeholders(_ value: String) -> [String] {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return pattern.matches(in: value, range: range).map {
                String(value[Range($0.range, in: value)!])
            }
        }
        for key in english.keys {
            XCTAssertEqual(placeholders(english[key]!), placeholders(chinese[key]!), key)
        }
        XCTAssertEqual(AppLanguage.english.text("随记"), "Quick Note")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("随记"), "随记")
        XCTAssertEqual(AppLanguage.english.text("unknown.resource.key"), "unknown.resource.key")
        XCTAssertEqual(AppLanguage.english.text("settings.editing"), "Editing")
    }

    func testResourceFormatsPreserveNumericValuesAndUntranslatedDiagnosticDetails() {
        XCTAssertEqual(NoteStoreError.sqlite(code: 14, message: nil).description(language: .english),
                       "SQLite error (14): Cannot open database")
        XCTAssertEqual(NoteStoreError.sqlite(code: 14, message: nil).description(language: .simplifiedChinese),
                       "SQLite 错误（14）：无法打开数据库")
        let detail = "user note 标题 %s 👩🏽‍💻"
        XCTAssertEqual(NoteStoreError.sqlite(code: 19, message: detail).description(language: .english),
                       "SQLite error (19): " + detail)
        XCTAssertEqual(NoteStoreError.sqlite(code: 19, message: detail).description(language: .simplifiedChinese),
                       "SQLite 错误（19）：" + detail)
        XCTAssertEqual(AppLanguage.english.format("%lld 字  ·  %@", Int64(1200), "Saved"),
                       "1,200 characters  ·  Saved")
        XCTAssertEqual(AppLanguage.simplifiedChinese.format("%lld 字  ·  %@", Int64(1200), "已保存"),
                       "1,200 字  ·  已保存")
        XCTAssertEqual(AppLanguage.english.format("command.tooltip", "Bold", "⌘B"), "Bold (⌘B)")
        XCTAssertEqual(AppLanguage.simplifiedChinese.format("command.tooltip", "粗体", "⌘B"), "粗体（⌘B）")
    }

    func testStoreErrorsRenderForTheSelectedLanguageWithoutChangingTheError() {
        let error = NoteStoreError.unsupportedSchema(1)
        XCTAssertTrue(error.description(language: .english).contains("version 1"))
        XCTAssertTrue(error.description(language: .simplifiedChinese).contains("版本为 1"))
        let invalid = NoteStoreError.invalidDatabase("Invalid note identifier")
        XCTAssertEqual(invalid.description(language: .english), "Invalid note database: Invalid note identifier")
        XCTAssertEqual(invalid.description(language: .simplifiedChinese), "备忘录数据库无效：备忘录标识无效")
    }
}
