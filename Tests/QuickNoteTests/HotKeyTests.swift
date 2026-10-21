import Carbon
import CoreGraphics
import XCTest
@testable import QuickNote

final class HotKeyTests: XCTestCase {
    func testFnQAcceptsOnlyNonRepeatingPlainFnQ() {
        XCTAssertTrue(FnQEventMatcher.matches(keyCode: Int64(kVK_ANSI_Q),
                                              flags: .maskSecondaryFn, isRepeat: false))
        XCTAssertFalse(FnQEventMatcher.matches(keyCode: Int64(kVK_ANSI_Q),
                                               flags: .maskSecondaryFn, isRepeat: true))
        XCTAssertFalse(FnQEventMatcher.matches(keyCode: Int64(kVK_ANSI_Q),
                                               flags: [], isRepeat: false))
        XCTAssertFalse(FnQEventMatcher.matches(keyCode: Int64(kVK_ANSI_N),
                                               flags: .maskSecondaryFn, isRepeat: false))
    }

    func testOtherModifierCombinationsDoNotTriggerFnQ() {
        for modifier: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate, .maskShift] {
            XCTAssertFalse(FnQEventMatcher.matches(keyCode: Int64(kVK_ANSI_Q),
                                                   flags: [.maskSecondaryFn, modifier], isRepeat: false))
        }
    }

    func testCapsLockDoesNotPreventFnQ() {
        XCTAssertTrue(FnQEventMatcher.matches(keyCode: Int64(kVK_ANSI_Q),
                                              flags: [.maskSecondaryFn, .maskAlphaShift], isRepeat: false))
    }

    func testFnQConsumesPressRepeatsAndReleaseButOnlyTriggersOnce() {
        var events = FnQEventProcessor()
        let q = Int64(kVK_ANSI_Q)
        XCTAssertEqual(events.process(type: .keyDown, keyCode: q,
                                      flags: .maskSecondaryFn, isRepeat: false), .triggerAndConsume)
        XCTAssertEqual(events.process(type: .keyDown, keyCode: q,
                                      flags: .maskSecondaryFn, isRepeat: true), .consume)
        // Releasing Fn before Q must not leak a repeat or Q key-up.
        XCTAssertEqual(events.process(type: .keyDown, keyCode: q,
                                      flags: [], isRepeat: true), .consume)
        XCTAssertEqual(events.process(type: .keyUp, keyCode: q,
                                      flags: [], isRepeat: false), .consume)
        // A subsequent ordinary Q remains normal text input.
        XCTAssertEqual(events.process(type: .keyDown, keyCode: q,
                                      flags: [], isRepeat: false), .passThrough)
        XCTAssertEqual(events.process(type: .keyUp, keyCode: q,
                                      flags: [], isRepeat: false), .passThrough)
    }

    func testUnrelatedEventsAlwaysPassThroughDuringCapturedPress() {
        var events = FnQEventProcessor()
        let q = Int64(kVK_ANSI_Q)
        XCTAssertEqual(events.process(type: .keyDown, keyCode: q,
                                      flags: .maskSecondaryFn, isRepeat: false), .triggerAndConsume)
        for type: CGEventType in [.keyDown, .keyUp] {
            XCTAssertEqual(events.process(type: type, keyCode: Int64(kVK_ANSI_N),
                                          flags: .maskSecondaryFn, isRepeat: false), .passThrough)
        }
        XCTAssertEqual(events.process(type: .flagsChanged, keyCode: q,
                                      flags: [], isRepeat: false), .passThrough)
    }

    func testModifierCombinationsPassThroughAndUnpairedRepeatNeverTriggers() {
        let q = Int64(kVK_ANSI_Q)
        for modifier: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate, .maskShift] {
            var events = FnQEventProcessor()
            XCTAssertEqual(events.process(type: .keyDown, keyCode: q,
                                          flags: [.maskSecondaryFn, modifier], isRepeat: false), .passThrough)
            XCTAssertEqual(events.process(type: .keyUp, keyCode: q,
                                          flags: [], isRepeat: false), .passThrough)
        }
        var events = FnQEventProcessor()
        XCTAssertEqual(events.process(type: .keyDown, keyCode: q,
                                      flags: .maskSecondaryFn, isRepeat: true), .consume)
        XCTAssertEqual(events.process(type: .keyUp, keyCode: q,
                                      flags: [], isRepeat: false), .consume)
        XCTAssertEqual(events.process(type: .keyDown, keyCode: q,
                                      flags: .maskSecondaryFn, isRepeat: false), .triggerAndConsume)
    }

    func testResetAfterDisabledTapClearsCapturedPress() {
        var events = FnQEventProcessor()
        let q = Int64(kVK_ANSI_Q)
        XCTAssertEqual(events.process(type: .keyDown, keyCode: q,
                                      flags: .maskSecondaryFn, isRepeat: false), .triggerAndConsume)
        events.reset()
        XCTAssertEqual(events.process(type: .keyDown, keyCode: q,
                                      flags: [], isRepeat: false), .passThrough)
    }
}
