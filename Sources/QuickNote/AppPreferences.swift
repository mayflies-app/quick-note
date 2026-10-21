import AppKit
import Combine
import CryptoKit
import QuickNoteCore

@MainActor
final class AppPreferences: ObservableObject {
    private static var usesSharedLocalizationSuite: Bool {
        CommandLine.arguments.contains("--verify-workflow") && CommandLine.arguments.contains("--settings-only")
            && ProcessInfo.processInfo.environment["MACOS_LOCALIZATION_TEST_SUITE"] != nil
    }
    private static let verificationSuite: String = {
        let arguments = CommandLine.arguments
        let path = arguments.firstIndex(of: "--database").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        } ?? UUID().uuidString
        if arguments.contains("--verify-workflow"), arguments.contains("--settings-only"),
           let suite = ProcessInfo.processInfo.environment["MACOS_LOCALIZATION_TEST_SUITE"] {
            guard let directory = ProcessInfo.processInfo.environment["MACOS_LOCALIZATION_TEST_DIRECTORY"] else {
                preconditionFailure("Missing localization fixture directory")
            }
            precondition(directory.hasPrefix("/") && directory.hasSuffix("/fixture-data"),
                         "Localization directory must be an absolute fixture-data path")
            // Foundation resolves existing /private/tmp directories to /tmp, but
            // leaves an absent database leaf unchanged. Validate existing parents
            // physically and hash the recorder's exact reserved output string.
            let outputPath = String(directory.dropLast("/fixture-data".count))
            let fixture = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
            let expectedParent = fixture.deletingLastPathComponent().appendingPathComponent("workflow")
                .standardizedFileURL.resolvingSymlinksInPath()
            let database = URL(fileURLWithPath: path)
            let databaseParent = database.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            let digest = SHA256.hash(data: Data(outputPath.utf8)).map { String(format: "%02x", $0) }.joined()
            precondition(database.lastPathComponent == "notes.sqlite" && databaseParent.path == expectedParent.path,
                         "Localization fixture data must remain in its native output")
            precondition(suite == "app.mayfiles.QuickNote.localization-test.\(digest)",
                         "Localization preference suite does not match the isolated output")
            return suite
        }
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "QuickNote.Verification.App.\(digest)"
    }()
    static let shared: AppPreferences = {
        guard CommandLine.arguments.contains("--verify-workflow") else { return AppPreferences() }
        // Native verification never modifies the user's preference domain.
        let defaults = UserDefaults(suiteName: verificationSuite)!
        if !CommandLine.arguments.contains("--read-back"), !usesSharedLocalizationSuite {
            defaults.removePersistentDomain(forName: verificationSuite)
        }
        return AppPreferences(defaults: defaults, preferredLanguages: ["zh-Hans"])
    }()
    static func cleanUpVerificationPreferences() {
        guard CommandLine.arguments.contains("--verify-workflow"),
              CommandLine.arguments.contains("--read-back") || CommandLine.arguments.contains("--window-shortcuts-only") else { return }
        guard !usesSharedLocalizationSuite else { return }
        UserDefaults(suiteName: verificationSuite)?.removePersistentDomain(forName: verificationSuite)
    }
    @Published var spellChecking: Bool { didSet { save() } }
    @Published var automaticLinks: Bool { didSet { save() } }
    @Published var floatingWindow: Bool { didSet { save() } }
    @Published var appearance: String { didSet { save() } }
    @Published private(set) var shortcut: GlobalShortcut
    @Published var language: AppLanguage { didSet { save() } }
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "globalShortcut"),
           let saved = try? JSONDecoder().decode(GlobalShortcut.self, from: data), saved.isValid {
            shortcut = saved
        } else { shortcut = .controlOptionN }
        language = defaults.string(forKey: "language").flatMap(AppLanguage.init(rawValue:))
            ?? AppLanguage.systemDefault(preferredLanguages: preferredLanguages)
        spellChecking = defaults.object(forKey: "spellChecking") as? Bool ?? true
        automaticLinks = defaults.object(forKey: "automaticLinks") as? Bool ?? true
        floatingWindow = defaults.object(forKey: "floatingWindow") as? Bool ?? true
        appearance = defaults.string(forKey: "appearance") ?? "system"
    }

    private let defaults: UserDefaults
    var nativeAppearance: NSAppearance? {
        switch appearance {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }

    /// Called only after the operating system accepts the new registration.
    func saveShortcut(_ value: GlobalShortcut) {
        guard value.isValid else { return }
        shortcut = value
        defaults.set(try? JSONEncoder().encode(value), forKey: "globalShortcut")
    }

    private func save() {
        defaults.set(spellChecking, forKey: "spellChecking")
        defaults.set(automaticLinks, forKey: "automaticLinks")
        defaults.set(floatingWindow, forKey: "floatingWindow")
        defaults.set(appearance, forKey: "appearance")
        defaults.set(language.rawValue, forKey: "language")
        onChange?()
    }
}
