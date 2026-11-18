import XCTest
@testable import TymeClone

final class RecordingRecoveryTests: XCTestCase {
    private var folder: URL!
    private var store: RecordingRecovery!
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var output: URL { folder.appendingPathComponent("output") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = RecordingRecovery(fileURL: folder.appendingPathComponent("state/recovery.json"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func begin() throws {
        try store.begin(task: "Café: Review, \"报价\"\nSecond line", at: start, folder: output)
    }

    private func relaunch() throws -> RecordingRecovery {
        let next = RecordingRecovery(fileURL: store.fileURL)
        try next.load()
        return next
    }

    private func rows() throws -> [[String]] {
        parseCSV(try String(contentsOf: output.appendingPathComponent("segments.csv")))
    }

    func testImmediateRecoveryAndTwoMinuteCheckpointInterval() throws {
        try begin()
        let id = try XCTUnwrap(store.recording).id
        XCTAssertEqual(try relaunch().recording?.checkpoint, start)
        try store.checkpoint(at: start.addingTimeInterval(119))
        XCTAssertEqual(try relaunch().recording?.checkpoint, start)
        try store.checkpoint(at: start.addingTimeInterval(120))
        XCTAssertEqual(try relaunch().recording?.checkpoint, start.addingTimeInterval(120))
        try store.checkpoint(at: start.addingTimeInterval(239))
        XCTAssertEqual(try relaunch().recording?.checkpoint, start.addingTimeInterval(120))
        try store.checkpoint(at: start.addingTimeInterval(240))
        let restored = try XCTUnwrap(relaunch().recording)
        XCTAssertEqual(restored.checkpoint, start.addingTimeInterval(240))
        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.outputFolder, output)
    }

    func testRecoveryExcludesDowntimeAndClearsJournal() throws {
        try begin()
        try store.checkpoint(at: start.addingTimeInterval(120))
        let next = try relaunch()
        try next.recover(endingAt: XCTUnwrap(next.recording).checkpoint, now: start.addingTimeInterval(86400))
        XCTAssertEqual(try rows().count, 2)
        XCTAssertEqual(try rows()[1][3], "00:02:00")
        XCTAssertNil(try relaunch().recording)
    }

    func testNormalSaveUsesExactEndAndRetainsFourColumnCSV() throws {
        try begin()
        try store.save(endingAt: start.addingTimeInterval(173))
        XCTAssertEqual(try rows()[1].count, 4)
        XCTAssertEqual(try rows()[1][0], "Café: Review, \"报价\"\nSecond line")
        XCTAssertEqual(try rows()[1][3], "00:02:53")
        XCTAssertNil(try relaunch().recording)
    }

    func testInterruptedBeforeCSVWriteCanFinishOnRelaunch() throws {
        try begin()
        try store.prepareSave(endingAt: start.addingTimeInterval(75))
        let next = try relaunch()
        try next.finishSave()
        XCTAssertEqual(try rows()[1][3], "00:01:15")
        XCTAssertNil(try relaunch().recording)
    }

    func testInterruptedAfterCSVWriteDoesNotDuplicateSegment() throws {
        try begin()
        try store.prepareSave(endingAt: start.addingTimeInterval(75))
        let commit = try XCTUnwrap(store.recording?.commit)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try commit.after.write(to: output.appendingPathComponent("segments.csv"), options: .atomic)
        let next = try relaunch()
        try next.finishSave()
        XCTAssertEqual(try rows().count, 2)
        XCTAssertNil(try relaunch().recording)
    }

    func testFailedCSVWriteRetainsJournalAndOriginalEndOnRetry() throws {
        try begin()
        try store.prepareSave(endingAt: start.addingTimeInterval(75))
        try Data("blocked".utf8).write(to: output)
        XCTAssertThrowsError(try store.finishSave())
        XCTAssertNotNil(try relaunch().recording?.commit)
        try FileManager.default.removeItem(at: output)
        try store.save(endingAt: start.addingTimeInterval(600))
        XCTAssertEqual(try rows()[1][3], "00:01:15")
    }

    func testExternalCSVChangesAreNotOverwritten() throws {
        try begin()
        try store.prepareSave(endingAt: start.addingTimeInterval(75))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let csv = output.appendingPathComponent("segments.csv")
        try Data("external change".utf8).write(to: csv)
        XCTAssertThrowsError(try relaunch().finishSave())
        XCTAssertEqual(try String(contentsOf: csv), "external change")
        XCTAssertNotNil(try relaunch().recording)
    }

    func testDiscardDoesNotCreateCSVAndAllowsFreshRecording() throws {
        try begin()
        let oldID = store.recording?.id
        try store.discard()
        XCTAssertNil(try relaunch().recording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try begin()
        XCTAssertNotEqual(store.recording?.id, oldID)
    }

    func testUnresolvedAndCorruptRecoveryCannotBeOverwritten() throws {
        try begin()
        XCTAssertThrowsError(try begin())
        let corrupt = Data("broken json".utf8)
        try corrupt.write(to: store.fileURL)
        XCTAssertThrowsError(try relaunch())
        XCTAssertThrowsError(try begin())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt)
    }

    func testAdjustedEndValidationAndRecovery() throws {
        try begin()
        XCTAssertThrowsError(try store.recover(endingAt: start.addingTimeInterval(-1), now: start.addingTimeInterval(300)))
        XCTAssertThrowsError(try store.recover(endingAt: start.addingTimeInterval(301), now: start.addingTimeInterval(300)))
        XCTAssertNotNil(try relaunch().recording)
        try store.recover(endingAt: start.addingTimeInterval(170), now: start.addingTimeInterval(300))
        XCTAssertEqual(try rows()[1][3], "00:02:50")
    }

    func testCheckpointCannotExtendPendingStop() throws {
        try begin()
        try store.prepareSave(endingAt: start.addingTimeInterval(60))
        try store.checkpoint(at: start.addingTimeInterval(600))
        XCTAssertEqual(try relaunch().recording?.checkpoint, start.addingTimeInterval(60))
    }
}
