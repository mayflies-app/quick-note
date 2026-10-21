import AppKit
import Carbon
import Combine
import ServiceManagement
import QuickNoteCore

enum LoginItemStatus: Equatable {
    case enabled, disabled, requiresApproval, unavailable
}

/// Keep ServiceManagement's registration states separate from the UI state.
enum LoginItemSystemStatus {
    case enabled, notRegistered, requiresApproval, notFound, unknown

    func status(hasApplicationBundle: Bool) -> LoginItemStatus {
        guard hasApplicationBundle else { return .unavailable }
        switch self {
        case .enabled: return .enabled
        case .notRegistered, .notFound: return .disabled
        case .requiresApproval: return .requiresApproval
        case .unknown: return .unavailable
        }
    }
}

@MainActor
protocol LoginItemManaging {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: LoginItemStatus
    @Published private(set) var error: String?
    private let manager: any LoginItemManaging
    private var operationError: Error?

    init(manager: any LoginItemManaging) {
        self.manager = manager
        status = manager.status
        refresh()
    }

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var canToggle: Bool { status != .unavailable }

    func refresh() {
        status = manager.status
        error = error(language: .systemDefault())
    }

    func setEnabled(_ enabled: Bool) {
        // A change in System Settings may have happened since the last displayed state.
        refresh()
        guard canToggle, enabled != isEnabled else { return }
        do {
            if enabled { try manager.register() } else { try manager.unregister() }
            operationError = nil
        } catch {
            operationError = error
        }
        // A successful register can still require approval; a throwing call can still change state.
        refresh()
    }

    func error(language: AppLanguage) -> String? {
        if status == .unavailable {
            return AppLocalization.text("此应用暂时无法设置登录时启动。请将随记放入应用程序文件夹，并检查系统登录项。", language: language)
        }
        guard let operationError else { return nil }
        return AppLocalization.text("无法更改登录时启动设置。请在系统设置中检查登录项后重试。", language: language)
            + "\n" + localizedError(operationError, language: language)
    }
    func openSystemSettings() { manager.openSystemSettings() }
}

@MainActor
enum LoginItemService {
    static func controller() -> LoginItemController {
        LoginItemController(manager: SystemLoginItemManager())
    }

    /// Workflow verification and previews never write real system registration.
    static func disabledMockController() -> LoginItemController {
        LoginItemController(manager: MockLoginItemManager())
    }
}

@MainActor
private final class SystemLoginItemManager: LoginItemManaging {
    private var hasApplicationBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    var status: LoginItemStatus {
        guard hasApplicationBundle else { return .unavailable }
        let systemStatus: LoginItemSystemStatus
        switch SMAppService.mainApp.status {
        case .enabled: systemStatus = .enabled
        case .notRegistered: systemStatus = .notRegistered
        case .requiresApproval: systemStatus = .requiresApproval
        case .notFound: systemStatus = .notFound
        @unknown default: systemStatus = .unknown
        }
        // A valid main app may be notFound until its first register attempt.
        return systemStatus.status(hasApplicationBundle: true)
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
private final class MockLoginItemManager: LoginItemManaging {
    var status: LoginItemStatus = .disabled
    func register() throws { status = .enabled }
    func unregister() throws { status = .disabled }
    func openSystemSettings() {}
}

enum LoginLaunch {
    static func isLoginLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    static func shouldShowWindow(for event: NSAppleEventDescriptor?, isVerification: Bool) -> Bool {
        isVerification || !isLoginLaunch(event)
    }
}
