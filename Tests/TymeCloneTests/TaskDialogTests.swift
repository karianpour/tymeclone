import AppKit
import XCTest
@testable import TymeClone

final class TaskDialogTests: XCTestCase {
    private func controls(_ dialog: TaskDialog) throws -> (project: NSComboBox, task: NSComboBox, table: NSTableView) {
        let combos = dialog.view.subviews.compactMap { $0 as? NSComboBox }.sorted { $0.frame.minY > $1.frame.minY }
        XCTAssertEqual(combos.count, 2)
        let scroll = try XCTUnwrap(dialog.view.subviews.compactMap { $0 as? NSScrollView }.first)
        return (combos[0], combos[1], try XCTUnwrap(scroll.documentView as? NSTableView))
    }

    func testRecentListAndEditableDropdownsSynchronizeWithoutConfirming() throws {
        _ = NSApplication.shared
        let button = NSButton(title: "Set", target: nil, action: nil)
        let history = TaskHistory(names: ["Orca: Shop", "Kson: Mesh", "Orca: Review", "Admin", "Kson: Profile", "Orca: Older"])
        let dialog = TaskDialog(currentName: "Orca: Shop", history: history, setButton: button)
        let fields = try controls(dialog)
        XCTAssertEqual(fields.table.numberOfRows, 5)
        XCTAssertTrue(fields.project.isEditable && fields.task.isEditable)
        XCTAssertEqual(fields.task.objectValues as? [String], ["Shop", "Review", "Older"])
        fields.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(dialog.fullNameField.stringValue, "Kson: Mesh")
        XCTAssertEqual(fields.project.stringValue, "Kson")
        XCTAssertEqual(fields.task.stringValue, "Mesh")
        XCTAssertEqual(fields.task.objectValues as? [String], ["Mesh", "Profile"])

        fields.project.selectItem(at: 0)
        dialog.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: fields.project))
        XCTAssertEqual(dialog.confirmedName, "Orca: Mesh")
        XCTAssertEqual(fields.task.objectValues as? [String], ["Shop", "Review", "Older"])
        XCTAssertEqual(fields.table.selectedRow, -1)
        fields.task.selectItem(at: 1)
        dialog.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: fields.task))
        XCTAssertEqual(dialog.confirmedName, "Orca: Review")

        fields.project.stringValue = "New project"
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fields.project))
        XCTAssertEqual(dialog.fullNameField.stringValue, "New project: Review")
        XCTAssertEqual(fields.task.stringValue, "Review")
        XCTAssertEqual(fields.task.numberOfItems, 0)
        XCTAssertEqual(history.recentTasks.first, "Orca: Shop")
    }

    func testFullNameEditsUpdateFieldsAndSetValidation() throws {
        _ = NSApplication.shared
        let button = NSButton(title: "Set", target: nil, action: nil)
        let dialog = TaskDialog(currentName: "Orca: Shop", history: TaskHistory(names: ["Kson: Mesh"]), setButton: button)
        let fields = try controls(dialog)
        dialog.fullNameField.stringValue = "Kson: "
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: dialog.fullNameField))
        XCTAssertEqual(fields.project.stringValue, "Kson")
        XCTAssertEqual(fields.task.stringValue, "")
        XCTAssertEqual(fields.task.objectValues as? [String], ["Mesh"])
        XCTAssertFalse(button.isEnabled)
        XCTAssertNil(dialog.confirmedName)
        fields.task.stringValue = "Mesh"
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fields.task))
        XCTAssertEqual(dialog.fullNameField.stringValue, "Kson: Mesh")
        XCTAssertTrue(button.isEnabled)
        dialog.fullNameField.stringValue = "Admin"
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: dialog.fullNameField))
        XCTAssertEqual(fields.project.stringValue, "")
        XCTAssertEqual(fields.task.stringValue, "Admin")
        XCTAssertEqual(dialog.confirmedName, "Admin")
    }

    func testEmptyHistoryStillAllowsTypingANewTask() throws {
        _ = NSApplication.shared
        let button = NSButton(title: "Set", target: nil, action: nil)
        let dialog = TaskDialog(currentName: "", history: TaskHistory(), setButton: button)
        let fields = try controls(dialog)
        XCTAssertEqual(fields.table.numberOfRows, 0)
        XCTAssertEqual(fields.project.numberOfItems, 0)
        XCTAssertEqual(fields.task.numberOfItems, 0)
        fields.project.stringValue = "First project"
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fields.project))
        XCTAssertFalse(button.isEnabled)
        fields.task.stringValue = "First task"
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fields.task))
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(dialog.confirmedName, "First project: First task")
    }
}
