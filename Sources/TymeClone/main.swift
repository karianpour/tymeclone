import AppKit
import IOKit

// Reads the system-wide HID idle time (seconds since last mouse/keyboard input),
// the same value macOS itself uses for screensaver/display-sleep timing.
func systemIdleSeconds() -> TimeInterval {
    var iterator: io_iterator_t = 0
    let matchResult = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iterator)
    guard matchResult == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(iterator) }

    let entry = IOIteratorNext(iterator)
    guard entry != 0 else { return 0 }
    defer { IOObjectRelease(entry) }

    var unmanagedDict: Unmanaged<CFMutableDictionary>?
    let kernResult = IORegistryEntryCreateCFProperties(entry, &unmanagedDict, kCFAllocatorDefault, 0)
    guard kernResult == KERN_SUCCESS,
          let props = unmanagedDict?.takeRetainedValue() as? [String: Any],
          let idleNs = props["HIDIdleTime"] as? UInt64 else {
        return 0
    }
    return TimeInterval(idleNs) / 1_000_000_000
}

// SF Symbols give pixel-precise size and baseline control, unlike emoji characters
// whose glyph metrics vary and don't line up cleanly with monospaced digit text.
func makeStatusIcon(systemName: String, tint: NSColor?, pointSize: CGFloat = NSFont.systemFontSize - 1) -> NSImage {
    let sizeConfig = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
    guard var image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
        .withSymbolConfiguration(sizeConfig) else {
        return NSImage()
    }
    if let tint {
        let paletteConfig = NSImage.SymbolConfiguration(paletteColors: [tint])
        image = image.withSymbolConfiguration(paletteConfig) ?? image
    } else {
        image.isTemplate = true
    }
    return image
}

let recordingRed = NSColor(calibratedRed: 0.7, green: 0.0, blue: 0.0, alpha: 1.0)
let recordingIcon = makeStatusIcon(systemName: "circle.fill", tint: recordingRed, pointSize: NSFont.systemFontSize - 6)
let idleIcon = makeStatusIcon(systemName: "square.fill", tint: nil)

// Fixed-width digits keep the status bar title from jittering as the seconds tick.
func statusBarTitle(icon: NSImage, text: String) -> NSAttributedString {
    let textFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    let iconSize = icon.size

    let attachment = NSTextAttachment()
    attachment.image = icon
    attachment.bounds = CGRect(
        x: 0,
        y: (textFont.capHeight - iconSize.height) / 2,
        width: iconSize.width,
        height: iconSize.height
    )

    let result = NSMutableAttributedString(attachment: attachment)
    result.append(NSAttributedString(string: " \(text)", attributes: [.font: textFont]))
    return result
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?

    private var timer = TaskTimer(taskName: "Unnamed task")
    private var isRecording: Bool { timer.startedAt != nil }
    private var sessionStart: Date? { timer.startedAt }
    private var currentTaskName: String { timer.taskName }
    private var taskHistoricalTotal: TimeInterval = 0
    private var idleThreshold: TimeInterval = 5 * 60
    private var hasPromptedForCurrentIdlePeriod = false
    private var showSeconds = true
    private var recentTasks: [String] = []
    private weak var taskDialogField: NSTextField?

    private var startStopItem: NSMenuItem!
    private var setTaskItem: NSMenuItem!
    private var taskTotalItem: NSMenuItem!
    private var showSecondsItem: NSMenuItem!
    private var outputFolderInfoItem: NSMenuItem!
    private var thresholdItems: [TimeInterval: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let savedTaskName = UserDefaults.standard.string(forKey: lastTaskNameDefaultsKey) ?? ""
        timer = TaskTimer(taskName: savedTaskName.isEmpty ? "Unnamed task" : savedTaskName)
        recentTasks = UserDefaults.standard.stringArray(forKey: recentTaskNamesDefaultsKey)
            .map { recentTaskNames(from: $0) } ?? initialRecentTaskNames(lastTask: savedTaskName)
        UserDefaults.standard.set(recentTasks, forKey: recentTaskNamesDefaultsKey)
        taskHistoricalTotal = totalDuration(forTask: currentTaskName)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.attributedTitle = statusBarTitle(icon: idleIcon, text: "00:00:00")

        let menu = NSMenu()

        startStopItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
        startStopItem.target = self
        menu.addItem(startStopItem)

        setTaskItem = NSMenuItem(title: "Set task (\(currentTaskName))", action: #selector(setCurrentTask), keyEquivalent: "")
        setTaskItem.target = self
        menu.addItem(setTaskItem)

        taskTotalItem = NSMenuItem(title: "Task Total: \(formatDuration(taskHistoricalTotal))", action: nil, keyEquivalent: "")
        taskTotalItem.isEnabled = false
        menu.addItem(taskTotalItem)

        menu.addItem(NSMenuItem.separator())

        let thresholdMenu = NSMenu()
        for minutes in [1, 3, 5, 10, 15] {
            let seconds = TimeInterval(minutes * 60)
            let item = NSMenuItem(title: "\(minutes) min", action: #selector(setThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = (seconds == idleThreshold) ? .on : .off
            thresholdMenu.addItem(item)
            thresholdItems[seconds] = item
        }
        let thresholdParent = NSMenuItem(title: "Idle Threshold", action: nil, keyEquivalent: "")
        thresholdParent.submenu = thresholdMenu
        menu.addItem(thresholdParent)

        showSecondsItem = NSMenuItem(title: "Show Seconds", action: #selector(toggleShowSeconds), keyEquivalent: "")
        showSecondsItem.target = self
        showSecondsItem.state = showSeconds ? .on : .off
        menu.addItem(showSecondsItem)

        let outputMenu = NSMenu()
        outputFolderInfoItem = NSMenuItem(title: currentOutputFolder().path, action: nil, keyEquivalent: "")
        outputFolderInfoItem.isEnabled = false
        outputMenu.addItem(outputFolderInfoItem)
        outputMenu.addItem(NSMenuItem.separator())
        let revealFolderItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealOutputFolder), keyEquivalent: "")
        revealFolderItem.target = self
        outputMenu.addItem(revealFolderItem)
        let chooseFolderItem = NSMenuItem(title: "Choose Output Folder\u{2026}", action: #selector(chooseOutputFolder), keyEquivalent: "")
        chooseFolderItem.target = self
        outputMenu.addItem(chooseFolderItem)
        let resetFolderItem = NSMenuItem(title: "Use Default Location", action: #selector(resetOutputFolder), keyEquivalent: "")
        resetFolderItem.target = self
        outputMenu.addItem(resetFolderItem)
        let outputParent = NSMenuItem(title: "Output Folder", action: nil, keyEquivalent: "")
        outputParent.submenu = outputMenu
        menu.addItem(outputParent)

        let exportItem = NSMenuItem(title: "Export Daily Summary\u{2026}", action: #selector(exportDailySummaryAction), keyEquivalent: "")
        exportItem.target = self
        menu.addItem(exportItem)

        let reportItem = NSMenuItem(title: "Open Report", action: #selector(openReport), keyEquivalent: "")
        reportItem.target = self
        menu.addItem(reportItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    @objc private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    @objc private func setCurrentTask() {
        let alert = NSAlert()
        alert.messageText = "Task"
        alert.informativeText = "What are you working on? Use Project: Task to group your report by project."
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 100))
        let textField = NSTextField(frame: NSRect(x: 0, y: 72, width: 340, height: 24))
        textField.stringValue = currentTaskName
        textField.placeholderString = "Project: Task, or a task name"
        textField.setAccessibilityLabel("Task name")
        accessory.addSubview(textField)

        let recentLabel = NSTextField(labelWithString: "Recent tasks")
        recentLabel.frame = NSRect(x: 0, y: 42, width: 340, height: 20)
        accessory.addSubview(recentLabel)
        let recentMenu = NSPopUpButton(frame: NSRect(x: 0, y: 8, width: 340, height: 28), pullsDown: false)
        recentMenu.addItem(withTitle: recentTasks.isEmpty ? "No recent tasks yet" : "Choose a recent task…")
        for task in recentTasks {
            let item = NSMenuItem(title: task, action: nil, keyEquivalent: "")
            item.representedObject = task
            recentMenu.menu?.addItem(item)
        }
        recentMenu.isEnabled = !recentTasks.isEmpty
        recentMenu.target = self
        recentMenu.action = #selector(selectRecentTask(_:))
        recentMenu.setAccessibilityLabel("Recent tasks")
        accessory.addSubview(recentMenu)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = textField
        taskDialogField = textField
        defer { taskDialogField = nil }

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let entered = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextTask = entered.isEmpty ? "Unnamed task" : entered
        let switchingWhileRecording = isRecording && nextTask != currentTaskName
        let switchedAt = Date()
        do {
            try timer.setTask(nextTask, at: switchedAt, save: saveSegment)
        } catch {
            showSaveError(error)
            return
        }
        UserDefaults.standard.set(currentTaskName, forKey: lastTaskNameDefaultsKey)
        rememberCurrentTask()
        setTaskItem.title = "Set task (\(currentTaskName))"
        taskHistoricalTotal = totalDuration(forTask: currentTaskName)
        taskTotalItem.title = "Task Total: \(formatDuration(taskHistoricalTotal))"
        if switchingWhileRecording { hasPromptedForCurrentIdlePeriod = false }
        updateTimerDisplay()
    }

    @objc private func selectRecentTask(_ sender: NSPopUpButton) {
        guard let task = sender.selectedItem?.representedObject as? String else { return }
        taskDialogField?.stringValue = task
    }

    private func rememberCurrentTask() {
        recentTasks = recentTaskNames(from: [currentTaskName] + recentTasks)
        UserDefaults.standard.set(recentTasks, forKey: recentTaskNamesDefaultsKey)
    }

    @objc private func setThreshold(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        idleThreshold = seconds
        for (value, item) in thresholdItems {
            item.state = (value == seconds) ? .on : .off
        }
    }

    @objc private func toggleShowSeconds() {
        showSeconds.toggle()
        showSecondsItem.state = showSeconds ? .on : .off
    }

    @objc private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder for segments.csv"

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: outputFolderDefaultsKey)
            outputFolderInfoItem.title = currentOutputFolder().path
        }
    }

    @objc private func resetOutputFolder() {
        UserDefaults.standard.removeObject(forKey: outputFolderDefaultsKey)
        outputFolderInfoItem.title = currentOutputFolder().path
    }

    @objc private func revealOutputFolder() {
        let folder = currentOutputFolder()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let csvURL = folder.appendingPathComponent("segments.csv")
            let selectedURL = FileManager.default.fileExists(atPath: csvURL.path) ? csvURL : folder
            NSWorkspace.shared.activateFileViewerSelecting([selectedURL])
        } catch {
            showError("Could not reveal output folder", detail: "\(folder.path)\n\(error.localizedDescription)")
        }
    }

    @objc private func exportDailySummaryAction() {
        let alert = NSAlert()
        do {
            let summaryURL = try exportDailySummary()
            alert.messageText = "Export complete"
            alert.informativeText = "daily_summary.csv was written to \(summaryURL.path)"
            alert.alertStyle = .informational
        } catch {
            alert.messageText = "Export failed"
            alert.informativeText = "No segments.csv found in \(currentOutputFolder().path) yet. Record something first."
            alert.alertStyle = .warning
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openReport() {
        do {
            let reportURL = try writeReportHTML()
            if !NSWorkspace.shared.open(reportURL) {
                showError("Could not open report", detail: "The report was saved to \(reportURL.path), but the default browser could not open it.")
            }
        } catch {
            showError("Could not write report.html", detail: error.localizedDescription)
        }
    }

    private func showError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func startRecording(at date: Date = Date()) {
        timer.start(at: date)
        rememberCurrentTask()
        hasPromptedForCurrentIdlePeriod = false
        startStopItem.title = "Stop Recording"
        print("Recording started at \(formatClock(sessionStart!)) for task '\(currentTaskName)'")
        updateTimerDisplay()
    }

    @discardableResult
    private func stopRecording(splitAt endDate: Date? = nil) -> Bool {
        let segment: RecordedSegment
        do {
            guard let saved = try timer.stop(at: endDate ?? Date(), save: saveSegment) else { return true }
            segment = saved
        } catch {
            showSaveError(error)
            return false
        }
        print("Segment: \(formatClock(segment.start)) - \(formatClock(segment.end)) (\(formatDuration(segment.duration))) [\(currentTaskName)]")
        taskHistoricalTotal += segment.duration
        taskTotalItem.title = "Task Total: \(formatDuration(taskHistoricalTotal))"
        startStopItem.title = "Start Recording"
        updateTimerDisplay()
        return true
    }

    private func showSaveError(_ error: Error) {
        showError("Could not save recording", detail: "The timer is still running for \(currentTaskName).\n\(error.localizedDescription)")
    }

    private func updateTimerDisplay() {
        guard isRecording, let start = sessionStart else {
            statusItem.button?.attributedTitle = statusBarTitle(icon: idleIcon, text: formatDuration(0, includeSeconds: showSeconds))
            return
        }

        let elapsed = Date().timeIntervalSince(start)
        statusItem.button?.attributedTitle = statusBarTitle(icon: recordingIcon, text: formatDuration(elapsed, includeSeconds: showSeconds))
        taskTotalItem.title = "Task Total: \(formatDuration(taskHistoricalTotal + elapsed))"
    }

    private func tick() {
        updateTimerDisplay()
        guard isRecording else { return }
        let idle = systemIdleSeconds()

        if idle >= idleThreshold && !hasPromptedForCurrentIdlePeriod {
            hasPromptedForCurrentIdlePeriod = true
            promptIdleDecision(idleSeconds: idle)
        } else if idle < 1 {
            hasPromptedForCurrentIdlePeriod = false
        }
    }

    private func promptIdleDecision(idleSeconds: TimeInterval) {
        let lastActive = Date().addingTimeInterval(-idleSeconds)

        let alert = NSAlert()
        alert.messageText = "Inactivity detected"
        alert.informativeText = "This Mac has not been used since \(formatClock(lastActive)) (\(formatDuration(idleSeconds)) idle). Keep counting the idle time, or split here and start a new segment now?"
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Split Here")
        alert.addButton(withTitle: "Stop")
        alert.alertStyle = .warning

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        switch response {
        case .alertSecondButtonReturn:
            // Close out the current segment at the last-active timestamp,
            // then immediately start a fresh one from now - the idle gap is excluded.
            if stopRecording(splitAt: lastActive) { startRecording() }
        case .alertThirdButtonReturn:
            // Stop for good at the last-active timestamp, no new segment starts.
            stopRecording(splitAt: lastActive)
        default:
            // "Keep Running": no action needed, the segment just continues uninterrupted.
            break
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
