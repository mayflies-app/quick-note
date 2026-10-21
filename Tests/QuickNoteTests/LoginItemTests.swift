import AppKit
import Carbon
import XCTest
@testable import QuickNote

@MainActor
final class LoginItemTests: XCTestCase {
    private enum Failure: LocalizedError {
        case refused
        var errorDescription: String? { "系统拒绝更改" }
    }

    private final class Manager: LoginItemManaging {
        var status: LoginItemStatus = .disabled
        var nextStatus: LoginItemStatus?
        var failure: Error?
        var registered = 0
        var unregistered = 0
        var settingsOpened = 0
        func register() throws {
            registered += 1
            if let nextStatus { status = nextStatus }
            if let failure { throw failure }
        }
        func unregister() throws {
            unregistered += 1
            if let nextStatus { status = nextStatus }
            if let failure { throw failure }
        }
        func openSystemSettings() { settingsOpened += 1 }
    }

    func testSystemStatesRequireAnApplicationAndNotFoundStillAllowsFirstRegistration() {
        for state in [LoginItemSystemStatus.enabled, .notRegistered, .requiresApproval, .notFound, .unknown] {
            XCTAssertEqual(state.status(hasApplicationBundle: false), .unavailable)
        }
        XCTAssertEqual(LoginItemSystemStatus.enabled.status(hasApplicationBundle: true), .enabled)
        XCTAssertEqual(LoginItemSystemStatus.notRegistered.status(hasApplicationBundle: true), .disabled)
        XCTAssertEqual(LoginItemSystemStatus.notFound.status(hasApplicationBundle: true), .disabled)
        XCTAssertEqual(LoginItemSystemStatus.requiresApproval.status(hasApplicationBundle: true), .requiresApproval)
        XCTAssertEqual(LoginItemSystemStatus.unknown.status(hasApplicationBundle: true), .unavailable)
        let manager = Manager()
        manager.status = LoginItemSystemStatus.notFound.status(hasApplicationBundle: true)
        manager.nextStatus = .enabled
        let controller = LoginItemController(manager: manager)
        controller.setEnabled(true)
        XCTAssertEqual(manager.registered, 1)
        XCTAssertEqual(controller.status, .enabled)
    }

    func testSuccessfulRegisterReadsApprovalRatherThanAssumingEnabled() {
        let manager = Manager()
        manager.nextStatus = .requiresApproval
        let controller = LoginItemController(manager: manager)
        controller.setEnabled(true)
        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(controller.canToggle)
        XCTAssertNil(controller.error)
        controller.openSystemSettings()
        XCTAssertEqual(manager.settingsOpened, 1)
        manager.nextStatus = .disabled
        controller.setEnabled(false)
        XCTAssertEqual(manager.unregistered, 1)
        XCTAssertFalse(controller.isEnabled)
    }

    func testFailureReReadsActualStateAndSuccessfulRetryClearsError() {
        let manager = Manager()
        manager.nextStatus = .requiresApproval
        manager.failure = Failure.refused
        let controller = LoginItemController(manager: manager)
        controller.setEnabled(true)
        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNotNil(controller.error)
        manager.failure = nil
        manager.nextStatus = .disabled
        controller.setEnabled(false)
        XCTAssertEqual(controller.status, .disabled)
        XCTAssertNil(controller.error)
    }

    func testFailedUnregisterKeepsSystemEnabledStateAndErrorAfterRefresh() {
        let manager = Manager()
        manager.status = .enabled
        manager.failure = Failure.refused
        let controller = LoginItemController(manager: manager)
        controller.setEnabled(false)
        controller.refresh()
        XCTAssertEqual(manager.unregistered, 1)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNotNil(controller.error)
    }

    func testExternalChangesAreReadBeforeToggleAndUnavailableCannotRegister() {
        let manager = Manager()
        let controller = LoginItemController(manager: manager)
        manager.status = .enabled
        controller.setEnabled(true)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertEqual(manager.registered, 0)
        manager.status = .unavailable
        controller.refresh()
        XCTAssertFalse(controller.canToggle)
        XCTAssertNotNil(controller.error)
        controller.setEnabled(true)
        XCTAssertEqual(manager.registered, 0)
        manager.status = .disabled
        controller.refresh()
        XCTAssertTrue(controller.canToggle)
        XCTAssertNil(controller.error)
    }

    func testExistingFailureAndUnavailableStateRenderInTheSelectedLanguage() {
        let manager = Manager()
        manager.failure = GlobalShortcutError.accessibilityRequired
        let controller = LoginItemController(manager: manager)
        controller.setEnabled(true)
        XCTAssertTrue(controller.error(language: .english)?.contains("Cannot change launch at login") == true)
        XCTAssertTrue(controller.error(language: .english)?.contains("Accessibility") == true)
        XCTAssertTrue(controller.error(language: .simplifiedChinese)?.contains("无法更改登录时启动设置") == true)
        manager.status = .unavailable
        controller.refresh()
        XCTAssertTrue(controller.error(language: .english)?.contains("Move Quick Note to Applications") == true)
        XCTAssertTrue(controller.error(language: .simplifiedChinese)?.contains("应用程序文件夹") == true)
    }

    func testVerificationMockIsFunctionalAndIsolatedFromSystem() {
        let controller = LoginItemService.disabledMockController()
        XCTAssertEqual(controller.status, .disabled)
        controller.setEnabled(true)
        XCTAssertEqual(controller.status, .enabled)
        controller.setEnabled(false)
        XCTAssertEqual(controller.status, .disabled)
    }

    func testLoginLaunchStaysInBackgroundAndVerificationAlwaysShowsWindow() {
        let loginEvent = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        loginEvent.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        XCTAssertTrue(LoginLaunch.isLoginLaunch(loginEvent))
        XCTAssertFalse(LoginLaunch.shouldShowWindow(for: loginEvent, isVerification: false))
        XCTAssertTrue(LoginLaunch.shouldShowWindow(for: loginEvent, isVerification: true))
        XCTAssertFalse(LoginLaunch.isLoginLaunch(nil))
        XCTAssertTrue(LoginLaunch.shouldShowWindow(for: nil, isVerification: false))
        let manualEvent = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        XCTAssertFalse(LoginLaunch.isLoginLaunch(manualEvent))
        XCTAssertTrue(LoginLaunch.shouldShowWindow(for: manualEvent, isVerification: false))
        let otherEvent = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        otherEvent.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        XCTAssertFalse(LoginLaunch.isLoginLaunch(otherEvent))
    }
}
