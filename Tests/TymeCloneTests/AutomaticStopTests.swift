import XCTest
@testable import TymeClone

final class AutomaticStopTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testStoppedTimerDoesNotPromptAfterLockAndSleep() {
        var state = AutomaticStopState()
        state.leave(.lock, recording: false, at: start)
        state.leave(.sleep, recording: false, at: start)
        state.returnFrom(.sleep)
        state.returnFrom(.lock)
        XCTAssertFalse(state.shouldPrompt)
        XCTAssertNil(state.pending)
    }

    func testOverlappingEventsPreserveFirstStopAndWaitForEveryReturn() {
        var state = AutomaticStopState()
        state.leave(.lock, recording: true, at: start)
        state.leave(.sleep, recording: false, at: start.addingTimeInterval(10))
        state.leave(.inactiveSession, recording: false, at: start.addingTimeInterval(20))
        XCTAssertEqual(state.pending?.date, start)
        XCTAssertEqual(state.pending?.reason, .lock)
        state.returnFrom(.sleep)
        XCTAssertFalse(state.shouldPrompt)
        state.returnFrom(.lock)
        XCTAssertFalse(state.shouldPrompt)
        state.returnFrom(.inactiveSession)
        XCTAssertTrue(state.shouldPrompt)
        state.acknowledge()
        state.returnFrom(.sleep)
        XCTAssertFalse(state.shouldPrompt)
    }

    func testSleepingAgainBeforeAnswerRetainsOriginalPrompt() {
        var state = AutomaticStopState()
        state.leave(.sleep, recording: true, at: start)
        state.returnFrom(.sleep)
        XCTAssertTrue(state.shouldPrompt)
        state.leave(.lock, recording: false, at: start.addingTimeInterval(100))
        XCTAssertFalse(state.shouldPrompt)
        state.returnFrom(.lock)
        XCTAssertEqual(state.pending?.date, start)
        XCTAssertTrue(state.shouldPrompt)
    }

    func testSaveAndExplicitRestartExcludeAbsence() throws {
        var timer = TaskTimer(taskName: "Work")
        var state = AutomaticStopState()
        var saved: [RecordedSegment] = []
        timer.start(at: start)
        state.leave(.sleep, recording: timer.startedAt != nil, at: start.addingTimeInterval(60))
        _ = try timer.stop(at: XCTUnwrap(state.pending).date) { saved.append($0) }
        XCTAssertNil(timer.startedAt)
        state.returnFrom(.sleep)
        XCTAssertTrue(state.shouldPrompt)
        XCTAssertEqual(saved.map(\.duration), [60])
        state.acknowledge()
        timer.start(at: start.addingTimeInterval(3600))
        XCTAssertEqual(timer.taskName, "Work")
        XCTAssertEqual(timer.startedAt, start.addingTimeInterval(3600))
    }

    func testFailedSaveRetainsOriginalCutoffAcrossFurtherEvents() throws {
        var timer = TaskTimer(taskName: "Work")
        var state = AutomaticStopState()
        timer.start(at: start)
        let cutoff = start.addingTimeInterval(60)
        state.leave(.lock, recording: true, at: cutoff)
        XCTAssertThrowsError(try timer.stop(at: cutoff) { _ in throw CocoaError(.fileWriteNoPermission) })
        state.leave(.sleep, recording: timer.startedAt != nil, at: start.addingTimeInterval(120))
        let pending = try XCTUnwrap(state.pending)
        let segment = try timer.stop(at: pending.date) { _ in }
        XCTAssertEqual(segment?.duration, 60)
        XCTAssertNil(timer.startedAt)
    }
}
