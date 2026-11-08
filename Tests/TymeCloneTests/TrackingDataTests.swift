import XCTest
@testable import TymeClone

final class TrackingDataTests: XCTestCase {
    private var folder: URL!
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TymeClone-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func save(_ segment: RecordedSegment) throws {
        try appendSegmentToCSV(task: segment.task, start: segment.start, end: segment.end, duration: segment.duration, folder: folder)
    }

    private func snapshot() throws -> [String: String] {
        let html = try makeReportHTML(folder: folder, generatedAt: start)
        let prefix = "id=\"snapshotData\">"
        let range = try XCTUnwrap(html.range(of: prefix))
        let encoded = html[range.upperBound...].prefix { $0 != "<" }
        let data = try XCTUnwrap(Data(base64Encoded: String(encoded)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    func testRecentTasksAreUniqueOrderedAndLimitedToFive() {
        XCTAssertEqual(recentTaskNames(from: ["A", "B", "A", "", " ", "C", "D", "E", "F"]), ["A", "B", "C", "D", "E"])
        XCTAssertEqual(recentTaskNames(from: ["C"] + ["A", "B", "C", "D", "E"]), ["C", "A", "B", "D", "E"])
    }

    func testRecentTasksComeFromLatestDistinctCSVRecords() throws {
        for name in ["A", "B", "C", "D", "E", "F", "B"] {
            try save(RecordedSegment(task: name, start: start, end: start.addingTimeInterval(60)))
        }
        XCTAssertEqual(recordedRecentTaskNames(folder: folder), ["B", "F", "E", "D", "C"])
    }

    func testRecentTasksReloadMigratedNamesFromDisk() throws {
        try save(RecordedSegment(task: "Orca - Shop", start: start, end: start.addingTimeInterval(60)))
        XCTAssertEqual(recordedRecentTaskNames(folder: folder), ["Orca - Shop"])
        let csvURL = folder.appendingPathComponent("segments.csv")
        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        try csv.replacingOccurrences(of: "Orca - Shop", with: "Orca: Shop")
            .write(to: csvURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(recordedRecentTaskNames(folder: folder), ["Orca: Shop"])
    }

    func testMissingAndEmptyCSVProduceNoRecentTasks() throws {
        XCTAssertEqual(recordedRecentTaskNames(folder: folder), [])
        try "Task,Start,End,Duration\n".write(to: folder.appendingPathComponent("segments.csv"), atomically: true, encoding: .utf8)
        XCTAssertEqual(recordedRecentTaskNames(folder: folder), [])
    }

    func testSwitchSavesOldTaskAndStartsNewTaskAtExactlySameTime() throws {
        var timer = TaskTimer(taskName: "Orca: Fix checkout")
        timer.start(at: start)
        let switchTime = start.addingTimeInterval(90)
        try timer.setTask("Orca: Meeting", at: switchTime, save: save)
        XCTAssertEqual(timer.taskName, "Orca: Meeting")
        XCTAssertEqual(timer.startedAt, switchTime)
        XCTAssertEqual(totalDuration(forTask: "Orca: Fix checkout", folder: folder), 90)
        XCTAssertEqual(totalDuration(forTask: "Orca: Meeting", folder: folder), 0)
        _ = try timer.stop(at: switchTime.addingTimeInterval(30), save: save)
        XCTAssertNil(timer.startedAt)
        XCTAssertEqual(totalDuration(forTask: "Orca: Meeting", folder: folder), 30)
    }

    func testFailedSavePreservesTaskAndStartAndCanBeRetried() throws {
        var timer = TaskTimer(taskName: "Original")
        timer.start(at: start)
        // A file in place of the directory forces a real filesystem failure.
        let blocked = folder.appendingPathComponent("blocked")
        try Data("untouched".utf8).write(to: blocked)
        XCTAssertThrowsError(try timer.setTask("Next", at: start.addingTimeInterval(60)) { segment in
            try appendSegmentToCSV(task: segment.task, start: segment.start, end: segment.end, duration: segment.duration, folder: blocked)
        })
        XCTAssertEqual(timer.taskName, "Original")
        XCTAssertEqual(timer.startedAt, start)
        XCTAssertEqual(try String(contentsOf: blocked), "untouched")
        XCTAssertThrowsError(try timer.stop(at: start.addingTimeInterval(70)) { _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertEqual(timer.startedAt, start)
        try timer.setTask("Next", at: start.addingTimeInterval(90), save: save)
        XCTAssertEqual(totalDuration(forTask: "Original", folder: folder), 90)
    }

    func testSameTaskDoesNotSplitAndStoppedTaskChangeDoesNotStartTimer() throws {
        var timer = TaskTimer(taskName: "A")
        try timer.setTask("B", at: start) { _ in XCTFail("Stopped timer must not save") }
        XCTAssertNil(timer.startedAt)
        timer.start(at: start)
        try timer.setTask("B", at: start.addingTimeInterval(30)) { _ in XCTFail("Same task must not split") }
        XCTAssertEqual(timer.startedAt, start)
    }

    func testIdleBoundaryCannotProduceNegativeDuration() throws {
        var timer = TaskTimer(taskName: "A")
        timer.start(at: start)
        let segment = try timer.stop(at: start.addingTimeInterval(-60), save: save)
        XCTAssertEqual(segment?.duration, 0)
    }

    func testCSVUnicodeQuotesAndMultilineTasksRoundTripInTotalsAndSummary() throws {
        let task = "Café: Review, \"报价\"\r\nSecond line\rThird line"
        try save(RecordedSegment(task: task, start: start, end: start.addingTimeInterval(60)))
        try save(RecordedSegment(task: task, start: start, end: start.addingTimeInterval(30)))
        let csv = try String(contentsOf: folder.appendingPathComponent("segments.csv"))
        let rows = parseCSV(csv)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1][0], task)
        XCTAssertEqual(totalDuration(forTask: task, folder: folder), 90)
        XCTAssertEqual(recordedRecentTaskNames(folder: folder), [task])
        let summary = try String(contentsOf: exportDailySummary(folder: folder))
        XCTAssertTrue(summary.contains(",00:01:30\n"))
        XCTAssertEqual(parseCSV("Task,Start,End,Duration\r\nA,s,e,00:01:00\r\n").count, 2)
    }

    func testAppendPreservesFileWithoutTrailingNewline() throws {
        let csvURL = folder.appendingPathComponent("segments.csv")
        let original = "Task,Start,End,Duration\nA,s,e,00:01:00"
        try original.write(to: csvURL, atomically: true, encoding: .utf8)
        try save(RecordedSegment(task: "B", start: start, end: start.addingTimeInterval(30)))
        let csv = try String(contentsOf: csvURL)
        XCTAssertTrue(csv.hasPrefix(original + "\n"))
        XCTAssertEqual(parseCSV(csv).count, 3)
    }

    func testSnapshotSafelyEmbedsUnicodeAndHTMLAndRefreshesFromDisk() throws {
        let task = "Café: </script><script>alert('x')</script> & 报价"
        try save(RecordedSegment(task: task, start: start, end: start.addingTimeInterval(60)))
        let first = try snapshot()
        XCTAssertEqual(first["source"], folder.appendingPathComponent("segments.csv").path)
        XCTAssertEqual(first["generatedAt"], ISO8601DateFormatter().string(from: start))
        XCTAssertTrue(try XCTUnwrap(first["csv"]).contains(task))
        XCTAssertFalse(try makeReportHTML(folder: folder).contains(task))
        try save(RecordedSegment(task: "New", start: start, end: start.addingTimeInterval(30)))
        XCTAssertNotEqual(try snapshot()["csv"], first["csv"])
    }

    func testMissingAndUnreadableCSVHaveDifferentSnapshotMessages() throws {
        let missing = try snapshot()
        XCTAssertNil(missing["csv"])
        XCTAssertTrue(try XCTUnwrap(missing["message"]).contains("No saved segments"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("segments.csv"), withIntermediateDirectories: true)
        let unreadable = try snapshot()
        XCTAssertNil(unreadable["csv"])
        XCTAssertTrue(try XCTUnwrap(unreadable["message"]).contains("Could not read"))
    }
}
