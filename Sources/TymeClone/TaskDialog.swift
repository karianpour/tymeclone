import AppKit

final class TaskDialog: NSObject, NSComboBoxDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 400))
    let fullNameField = NSTextField(frame: NSRect(x: 0, y: 344, width: 440, height: 26))
    private let projectField = NSComboBox(frame: NSRect(x: 0, y: 106, width: 440, height: 26))
    private let taskField = NSComboBox(frame: NSRect(x: 0, y: 46, width: 440, height: 26))
    private let recentTable = NSTableView()
    private let validationLabel = NSTextField(wrappingLabelWithString: "")
    private let history: TaskHistory
    private weak var setButton: NSButton?
    private var updatingFields = false
    private var draft: TaskNameDraft

    var confirmedName: String? { draft.confirmedName }

    init(currentName: String, history: TaskHistory, setButton: NSButton) {
        self.history = history
        self.setButton = setButton
        draft = TaskNameDraft(fullName: currentName)
        super.init()

        addLabel("Full task name", y: 374)
        fullNameField.placeholderString = "Project: Task, or a task name"
        fullNameField.setAccessibilityLabel("Full task name")
        fullNameField.delegate = self
        view.addSubview(fullNameField)

        addLabel("Recent tasks", y: 314)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 164, width: 440, height: 144))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("task"))
        column.width = 416
        recentTable.addTableColumn(column)
        recentTable.headerView = nil
        recentTable.rowHeight = 26
        recentTable.intercellSpacing = NSSize(width: 0, height: 2)
        recentTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        recentTable.allowsMultipleSelection = false
        recentTable.allowsEmptySelection = true
        recentTable.usesAlternatingRowBackgroundColors = true
        recentTable.setAccessibilityLabel("Recent tasks")
        recentTable.delegate = self
        recentTable.dataSource = self
        scroll.documentView = recentTable
        view.addSubview(scroll)
        if history.recentTasks.isEmpty {
            let empty = NSTextField(labelWithString: "No recent tasks yet")
            empty.frame = NSRect(x: 12, y: 272, width: 410, height: 20)
            empty.textColor = .secondaryLabelColor
            view.addSubview(empty)
        }

        addLabel("Project", y: 136)
        addLabel("Task", y: 76)
        for (field, label) in [(projectField, "Project"), (taskField, "Task")] {
            field.isEditable = true
            field.completes = false
            field.delegate = self
            field.setAccessibilityLabel(label)
            view.addSubview(field)
        }
        projectField.placeholderString = "Type a project or choose a recent one"
        projectField.addItems(withObjectValues: history.recentProjects)
        projectField.numberOfVisibleItems = 5
        taskField.placeholderString = "Type a task or choose one for this project"
        taskField.numberOfVisibleItems = 10

        validationLabel.frame = NSRect(x: 0, y: 0, width: 440, height: 38)
        validationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        validationLabel.textColor = .secondaryLabelColor
        view.addSubview(validationLabel)

        fullNameField.nextKeyView = recentTable
        recentTable.nextKeyView = projectField
        projectField.nextKeyView = taskField
        taskField.nextKeyView = setButton
        synchronizeFields()
    }

    private func addLabel(_ title: String, y: CGFloat) {
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 0, y: y, width: 440, height: 20)
        view.addSubview(label)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        history.recentTasks.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let name = history.recentTasks[row]
        let label = NSTextField(labelWithString: name)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = name
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingFields, recentTable.selectedRow >= 0 else { return }
        draft.editFullName(history.recentTasks[recentTable.selectedRow])
        synchronizeFields()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        applyEdit(from: field)
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard !updatingFields, let field = notification.object as? NSComboBox,
              let selected = field.objectValueOfSelectedItem as? String else { return }
        // Read the selected item explicitly: the text editor may still show the
        // previous value when AppKit delivers the selection notification.
        updatingFields = true
        field.stringValue = selected
        field.currentEditor()?.string = selected
        updatingFields = false
        applyEdit(from: field)
    }

    private func applyEdit(from field: NSTextField) {
        guard !updatingFields else { return }
        updatingFields = true
        defer { updatingFields = false }
        if field === fullNameField {
            draft.editFullName(fullNameField.stringValue)
            projectField.stringValue = draft.project
            taskField.stringValue = draft.task
            refreshTaskSuggestions()
        } else {
            draft.editParts(project: projectField.stringValue, task: taskField.stringValue)
            fullNameField.stringValue = draft.fullName
            if field === projectField { refreshTaskSuggestions() }
        }
        recentTable.deselectAll(nil)
        updateValidation()
    }

    private func synchronizeFields() {
        updatingFields = true
        defer { updatingFields = false }
        fullNameField.stringValue = draft.fullName
        projectField.stringValue = draft.project
        taskField.stringValue = draft.task
        refreshTaskSuggestions()
        updateValidation()
    }

    private func refreshTaskSuggestions() {
        let text = taskField.stringValue
        taskField.removeAllItems()
        taskField.addItems(withObjectValues: history.tasks(for: projectField.stringValue))
        taskField.stringValue = text
    }

    private func updateValidation() {
        setButton?.isEnabled = draft.confirmedName != nil
        validationLabel.stringValue = draft.validationMessage ?? ""
    }
}
