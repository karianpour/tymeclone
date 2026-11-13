import XCTest
@testable import TymeClone

final class TaskSelectionTests: XCTestCase {
    func testHistoryKeepsFiveProjectsAndTenDistinctTasksForEachProject() {
        let orca = (1...12).map { "Orca: Task \($0)" }
        let history = TaskHistory(names: ["Orca: Task 1", "Kson: Mesh", "Admin"] + orca + [
            " Client A : Review ", "Client B: Review", "Client C: Review", "Client D: Review", "Kson: Mesh"
        ])
        XCTAssertEqual(history.recentTasks, ["Orca: Task 1", "Kson: Mesh", "Admin", "Orca: Task 2", "Orca: Task 3"])
        XCTAssertEqual(history.recentProjects, ["Orca", "Kson", "Client A", "Client B", "Client C"])
        XCTAssertEqual(history.tasks(for: " Orca "), (1...10).map { "Task \($0)" })
        XCTAssertEqual(history.tasks(for: "Kson"), ["Mesh"])
        XCTAssertEqual(history.tasks(for: "Client D"), ["Review"])
        XCTAssertEqual(history.tasks(for: "New project"), [])
        XCTAssertEqual(history.tasks(for: ""), ["Admin"])
    }

    func testConfirmedNamesMoveToFrontWithoutDroppingOlderProjectTasks() {
        var history = TaskHistory(names: (1...12).map { "Orca: Task \($0)" } + ["Kson: Mesh"])
        history.remember("Kson: Mesh")
        history.remember("Orca: Task 12")
        XCTAssertEqual(history.recentTasks.first, "Orca: Task 12")
        XCTAssertEqual(history.recentProjects, ["Orca", "Kson"])
        XCTAssertEqual(history.tasks(for: "Orca"), ["Task 12"] + (1...9).map { "Task \($0)" })
        XCTAssertEqual(history.names.count, 13)
    }

    func testCSVHistoryRetainsMoreThanFiveRecordsAndQuotedNames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = (1...12).map { "Orca: Task \($0)" } + ["Kson: Mesh, \"v2\"", "Client A: Review: follow-up"]
        let csv = "Task,Start,End,Duration\n" + names.map { "\(csvField($0)),2026-11-13 09:00:00,2026-11-13 09:01:00,00:01:00\n" }.joined()
        try csv.write(to: folder.appendingPathComponent("segments.csv"), atomically: true, encoding: .utf8)
        let history = recordedTaskHistory(folder: folder)
        XCTAssertEqual(history.recentProjects, ["Client A", "Kson", "Orca"])
        XCTAssertEqual(history.tasks(for: "Orca"), (3...12).reversed().map { "Task \($0)" })
        XCTAssertEqual(history.tasks(for: "Kson"), ["Mesh, \"v2\""])
        XCTAssertEqual(history.tasks(for: "Client A"), ["Review: follow-up"])
    }

    func testFullNameEditingSynchronizesPartsAndPreservesFurtherColons() {
        var draft = TaskNameDraft(fullName: "Orca: Shop")
        XCTAssertEqual(draft.project, "Orca")
        XCTAssertEqual(draft.task, "Shop")
        draft.editFullName(" Client A : Review: follow-up ")
        XCTAssertEqual(draft.project, "Client A")
        XCTAssertEqual(draft.task, "Review: follow-up")
        XCTAssertEqual(draft.confirmedName, "Client A : Review: follow-up")
        draft.editFullName("Admin")
        XCTAssertEqual(draft.project, "")
        XCTAssertEqual(draft.task, "Admin")
        XCTAssertEqual(draft.confirmedName, "Admin")
    }

    func testStructuredEditingPreservesTaskWhenChangingProject() {
        var draft = TaskNameDraft(fullName: "Orca: Shop")
        draft.editParts(project: "Kson", task: draft.task)
        XCTAssertEqual(draft.fullName, "Kson: Shop")
        XCTAssertEqual(draft.task, "Shop")
        draft.editParts(project: " Kson ", task: " Review: follow-up ")
        XCTAssertEqual(draft.confirmedName, "Kson: Review: follow-up")
        draft.editParts(project: "", task: "Admin")
        XCTAssertEqual(draft.confirmedName, "Admin")
    }

    func testProjectRequiresTaskAndBlankNameKeepsExistingFallback() {
        var draft = TaskNameDraft(fullName: "Orca: ")
        XCTAssertNil(draft.confirmedName)
        XCTAssertEqual(draft.validationMessage, "Enter a task for this project.")
        draft.editParts(project: "Orca", task: "   ")
        XCTAssertNil(draft.confirmedName)
        draft.editParts(project: "Orca", task: "Shop")
        XCTAssertEqual(draft.confirmedName, "Orca: Shop")
        draft.editParts(project: "Client: A", task: "Shop")
        XCTAssertNil(draft.confirmedName)
        draft.editFullName("  ")
        XCTAssertEqual(draft.confirmedName, "Unnamed task")
    }

    func testHistoryParsingMatchesReportConventionAndDeduplicatesParts() {
        let history = TaskHistory(names: ["Orca: Shop", " Orca : Shop ", "Orca: Review: follow-up", "Project:", ": Admin", ""])
        XCTAssertEqual(history.recentProjects, ["Orca"])
        XCTAssertEqual(history.tasks(for: "Orca"), ["Shop", "Review: follow-up"])
        XCTAssertEqual(history.tasks(for: ""), ["Project:", ": Admin"])
    }

}
