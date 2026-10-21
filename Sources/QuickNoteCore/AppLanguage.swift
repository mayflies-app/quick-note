import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public var title: String { text("language.name") }
    public var locale: Locale { Locale(identifier: rawValue) }
    public var appName: String { text("随记") }
    private static var resourceBundle: Bundle {
        LocalizationResources.bundle(named: "QuickNote_QuickNoteCore.bundle", fallback: { Bundle.module })
    }
    public var catalog: [String: String] {
        LocalizationResources.catalog(language: rawValue, bundle: Self.resourceBundle)
    }
    public func text(_ key: String) -> String {
        LocalizationResources.string(key, language: rawValue, bundle: Self.resourceBundle)
    }
    public func format(_ key: String, _ arguments: CVarArg...) -> String {
        LocalizationResources.format(key, language: rawValue, bundle: Self.resourceBundle, arguments: arguments)
    }
    public static func systemDefault(preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        for language in preferredLanguages {
            let code = language.lowercased().split(separator: "-").first
            if code == "zh" { return .simplifiedChinese }
            if code == "en" { return .english }
        }
        return .english
    }
}
