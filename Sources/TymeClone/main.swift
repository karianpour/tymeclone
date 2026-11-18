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
    private var terminationSignals: TerminationSignals?
    private var isQuitting = false
    private let recovery = RecordingRecovery()
    private var recoveryNeedsReview = true
    private var checkpointTimer: Timer?
    private var checkpointError: Error?

    private var timer = TaskTimer(taskName: "Unnamed task")
    private var isRecording: Bool { timer.startedAt != nil }
    private var sessionStart: Date? { timer.startedAt }
    private var currentTaskName: String { timer.taskName }
    private var taskHistoricalTotal: TimeInterval = 0
    private var idleThreshold: TimeInterval = 5 * 60
    private var hasPromptedForCurrentIdlePeriod = false
    private var automaticStop = AutomaticStopState()
    private var interruptionAlert: NSAlert?
    private var automaticSaveError: Error?
    private var showSeconds = true
    private var taskHistory = TaskHistory()

    private var startStopItem: NSMenuItem!
    private var setTaskItem: NSMenuItem!
    private var taskTotalItem: NSMenuItem!
    private var showSecondsItem: NSMenuItem!
    private var outputFolderInfoItem: NSMenuItem!
    private var thresholdItems: [TimeInterval: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let savedTaskName = UserDefaults.standard.string(forKey: lastTaskNameDefaultsKey) ?? ""
        timer = TaskTimer(taskName: savedTaskName.isEmpty ? "Unnamed task" : savedTaskName)
        taskHistory = recordedTaskHistory()
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

        observeAvailability()
        terminationSignals = TerminationSignals { [weak self] in
            guard let self, !self.isQuitting else { return }
            NSApp.terminate(nil)
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        DispatchQueue.main.async { [weak self] in self?.reviewRecovery() }
    }

    private func reviewRecovery() {
        guard recoveryNeedsReview, !isRecording, !isQuitting, !automaticStop.isAway,
              NSApp.modalWindow == nil else { return }
        do {
            try recovery.load()
            // Complete an already requested save. The journal detects whether the
            // CSV replacement happened before the process was killed.
            if recovery.recording?.commit != nil { try recovery.finishSave() }
            guard let saved = recovery.recording else {
                recoveryNeedsReview = false
                refreshRecordedTotals()
                return
            }
            while true {
                let alert = NSAlert()
                alert.messageText = "Recover interrupted recording?"
                alert.informativeText = "Task: \(saved.task)\nStarted: \(formatDateTime(saved.start))\nLast checkpoint: \(formatDateTime(saved.checkpoint))\nRecoverable time: \(formatDuration(saved.checkpoint.timeIntervalSince(saved.start)))\n\nCheckpoints are saved every 2 minutes. Time after the last checkpoint is not included. The recording will remain stopped."
                alert.addButton(withTitle: "Recover Recording")
                alert.addButton(withTitle: "Adjust End Time…")
                alert.addButton(withTitle: "Discard Recording")
                interruptionAlert = alert
                NSApp.activate(ignoringOtherApps: true)
                let response = alert.runModal()
                interruptionAlert = nil
                guard !automaticStop.isAway, response != .abort else { return }
                switch response {
                case .alertFirstButtonReturn:
                    try recovery.recover(endingAt: saved.checkpoint)
                case .alertSecondButtonReturn:
                    guard let end = adjustedRecoveryEnd(for: saved) else {
                        if automaticStop.isAway { return }
                        continue
                    }
                    try recovery.recover(endingAt: end)
                case .alertThirdButtonReturn:
                    try recovery.discard()
                default: continue
                }
                recoveryNeedsReview = false
                refreshRecordedTotals()
                return
            }
        } catch {
            showError("Could not recover recording", detail: "The recovery file has been preserved. Choose Start Recording to retry recovery before starting a new recording.\n\(error.localizedDescription)")
        }
    }

    private func adjustedRecoveryEnd(for saved: RecoveryRecording) -> Date? {
        let alert = NSAlert()
        alert.messageText = "Adjust recording end time"
        alert.informativeText = "Choose when you stopped working on ‘\(saved.task)’. Started: \(formatDateTime(saved.start))."
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        picker.minDate = saved.start
        picker.maxDate = Date()
        picker.dateValue = saved.checkpoint
        alert.accessoryView = picker
        alert.addButton(withTitle: "Recover Recording")
        alert.addButton(withTitle: "Cancel")
        interruptionAlert = alert
        let response = alert.runModal()
        interruptionAlert = nil
        guard response == .alertFirstButtonReturn, !automaticStop.isAway else { return nil }
        return picker.dateValue
    }

    private func refreshRecordedTotals() {
        taskHistoricalTotal = totalDuration(forTask: currentTaskName)
        taskHistory = recordedTaskHistory()
        taskTotalItem.title = "Task Total: \(formatDuration(taskHistoricalTotal))"
    }

    private func scheduleCheckpoints() {
        checkpointTimer?.invalidate()
        let checkpointTimer = Timer(timeInterval: RecordingRecovery.checkpointInterval, repeats: false) { [weak self] _ in
            guard let self, self.isRecording else { return }
            defer { if self.isRecording { self.scheduleCheckpoints() } }
            guard !self.automaticStop.isAway, self.automaticStop.pending == nil,
                  !self.isQuitting else { return }
            do { try self.recovery.checkpoint(at: Date()) }
            catch { self.checkpointError = error }
        }
        self.checkpointTimer = checkpointTimer
        // Checkpoint even while a menu or idle/task dialog is open.
        RunLoop.main.add(checkpointTimer, forMode: .common)
        RunLoop.main.add(checkpointTimer, forMode: .modalPanel)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitting else { return .terminateCancel }
        isQuitting = true
        // Saving is synchronous; keep the app and its active segment alive on failure.
        guard stopRecording() else {
            isQuitting = false
            return .terminateCancel
        }
        return .terminateNow
    }

    private func observeAvailability() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionInactive), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        // macOS distributes screen-lock events separately from workspace sleep events.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenLocked), name: Notification.Name("com.apple.screenIsLocked"), object: nil, suspensionBehavior: .deliverImmediately)
        distributed.addObserver(self, selector: #selector(screenUnlocked), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func willSleep(_ notification: Notification) { leave(.sleep) }
    @objc private func didWake(_ notification: Notification) { returned(.sleep) }
    @objc private func screenLocked(_ notification: Notification) { leave(.lock) }
    @objc private func screenUnlocked(_ notification: Notification) { returned(.lock) }
    @objc private func sessionInactive(_ notification: Notification) { leave(.inactiveSession) }
    @objc private func sessionActive(_ notification: Notification) { returned(.inactiveSession) }

    private func leave(_ reason: AutomaticStopState.Absence) {
        automaticStop.leave(reason, recording: isRecording, at: Date())
        if let alert = interruptionAlert {
            NSApp.abortModal()
            alert.window.orderOut(nil)
        }
        guard let pending = automaticStop.pending, isRecording else { return }
        // Save synchronously before sleep. Defer any error UI until the user returns.
        stopRecording(splitAt: pending.date, automatic: true)
    }

    private func returned(_ reason: AutomaticStopState.Absence) {
        automaticStop.returnFrom(reason)
        // Allow overlapping wake/unlock notifications and aborted modal loops to settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.reviewRecovery()
            self?.promptAutomaticStopIfNeeded()
        }
    }

    private func promptAutomaticStopIfNeeded() {
        guard !isQuitting, automaticStop.shouldPrompt, interruptionAlert == nil,
              NSApp.modalWindow == nil, let pending = automaticStop.pending else { return }
        if let error = automaticSaveError {
            automaticSaveError = nil
            showError("Could not save automatic stop", detail: "The recording is held at \(formatClock(pending.date)). Choose Stop Recording to retry saving.\n\(error.localizedDescription)")
            return
        }
        guard !isRecording else { return }
        let alert = NSAlert()
        alert.messageText = "Recording stopped automatically"
        alert.informativeText = "Recording for ‘\(currentTaskName)’ was saved at \(formatClock(pending.date)) because \(pending.reason.description). Would you like to start recording again?"
        alert.addButton(withTitle: "Start Recording")
        alert.addButton(withTitle: "Keep Stopped").keyEquivalent = "\u{1b}"
        interruptionAlert = alert
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        interruptionAlert = nil
        guard !automaticStop.isAway, response != .abort else { return }
        automaticStop.acknowledge()
        if response == .alertFirstButtonReturn { startRecording() }
    }

    @objc private func toggleRecording() {
        if recoveryNeedsReview { reviewRecovery(); return }
        guard !automaticStop.isAway else { return }
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    @objc private func setCurrentTask() {
        guard !automaticStop.isAway, automaticStop.pending == nil, recovery.recording?.commit == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Task"
        alert.informativeText = "Choose a recent task, edit the full name, or enter a project and task below."
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational

        let dialog = TaskDialog(currentName: currentTaskName, history: taskHistory, setButton: alert.buttons[0])
        alert.accessoryView = dialog.view
        alert.window.initialFirstResponder = dialog.fullNameField

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              !automaticStop.isAway, automaticStop.pending == nil,
              let nextTask = dialog.confirmedName else { return }

        let switchingWhileRecording = isRecording && nextTask != currentTaskName
        let switchedAt = Date()
        if switchingWhileRecording && !stopRecording(splitAt: switchedAt) { return }
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
        if switchingWhileRecording { startRecording(at: switchedAt) }
        updateTimerDisplay()
    }

    private func rememberCurrentTask() {
        taskHistory.remember(currentTaskName)
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
            taskHistory = recordedTaskHistory()
        }
    }

    @objc private func resetOutputFolder() {
        UserDefaults.standard.removeObject(forKey: outputFolderDefaultsKey)
        outputFolderInfoItem.title = currentOutputFolder().path
        taskHistory = recordedTaskHistory()
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
        guard !automaticStop.isAway, !recoveryNeedsReview else { return }
        do { try recovery.begin(task: currentTaskName, at: date, folder: currentOutputFolder()) }
        catch {
            showError("Could not start recording", detail: "Recording was not started because its recovery information could not be saved.\n\(error.localizedDescription)")
            return
        }
        automaticStop.acknowledge()
        timer.start(at: date)
        checkpointError = nil
        scheduleCheckpoints()
        rememberCurrentTask()
        hasPromptedForCurrentIdlePeriod = false
        startStopItem.title = "Stop Recording"
        print("Recording started at \(formatClock(sessionStart!)) for task '\(currentTaskName)'")
        updateTimerDisplay()
    }

    @discardableResult
    private func stopRecording(splitAt endDate: Date? = nil, automatic: Bool = false) -> Bool {
        let segment: RecordedSegment
        do {
            let end = recovery.recording?.commit?.end ?? automaticStop.pending?.date ?? endDate ?? Date()
            guard let saved = try timer.stop(at: end, save: { segment in
                try recovery.save(endingAt: segment.end)
            }) else { return true }
            segment = saved
        } catch {
            if automatic { automaticSaveError = error } else { showSaveError(error) }
            return false
        }
        print("Segment: \(formatClock(segment.start)) - \(formatClock(segment.end)) (\(formatDuration(segment.duration))) [\(currentTaskName)]")
        automaticSaveError = nil
        checkpointTimer?.invalidate()
        checkpointTimer = nil
        checkpointError = nil
        taskHistoricalTotal = totalDuration(forTask: currentTaskName)
        taskTotalItem.title = "Task Total: \(formatDuration(taskHistoricalTotal))"
        startStopItem.title = "Start Recording"
        updateTimerDisplay()
        return true
    }

    private func showSaveError(_ error: Error) {
        let status = recovery.recording?.commit == nil && automaticStop.pending == nil
            ? "The timer is still running for \(currentTaskName)."
            : "The recording is held at its stop time. Choose Stop Recording to retry."
        showError("Could not save recording", detail: "\(status)\n\(error.localizedDescription)")
    }

    private func updateTimerDisplay() {
        guard isRecording, let start = sessionStart else {
            statusItem.button?.attributedTitle = statusBarTitle(icon: idleIcon, text: formatDuration(0, includeSeconds: showSeconds))
            return
        }

        let elapsed = (recovery.recording?.commit?.end ?? automaticStop.pending?.date ?? Date()).timeIntervalSince(start)
        statusItem.button?.attributedTitle = statusBarTitle(icon: recordingIcon, text: formatDuration(elapsed, includeSeconds: showSeconds))
        taskTotalItem.title = "Task Total: \(formatDuration(taskHistoricalTotal + elapsed))"
    }

    private func tick() {
        guard !isQuitting else { return }
        updateTimerDisplay()
        if let error = checkpointError, NSApp.modalWindow == nil, !automaticStop.isAway {
            checkpointError = nil
            showError("Could not update recovery checkpoint", detail: "Recording continues, but recovery may use an older checkpoint.\n\(error.localizedDescription)")
        }
        promptAutomaticStopIfNeeded()
        guard isRecording, !automaticStop.isAway, automaticStop.pending == nil,
              recovery.recording?.commit == nil, interruptionAlert == nil else { return }
        let idle = systemIdleSeconds()

        if idle >= idleThreshold && !hasPromptedForCurrentIdlePeriod {
            hasPromptedForCurrentIdlePeriod = true
            promptIdleDecision(idleSeconds: idle)
        } else if idle < 1 {
            hasPromptedForCurrentIdlePeriod = false
        }
    }

    private func promptIdleDecision(idleSeconds: TimeInterval) {
        let promptedSessionStart = sessionStart
        let lastActive = Date().addingTimeInterval(-idleSeconds)

        let alert = NSAlert()
        alert.messageText = "Inactivity detected"
        alert.informativeText = "This Mac has not been used since \(formatClock(lastActive)) (\(formatDuration(idleSeconds)) idle). Keep counting the idle time, or split here and start a new segment now?"
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Split Here")
        alert.addButton(withTitle: "Stop")
        alert.alertStyle = .warning

        NSApp.activate(ignoringOtherApps: true)
        interruptionAlert = alert
        let response = alert.runModal()
        interruptionAlert = nil
        guard response != .abort, !automaticStop.isAway, automaticStop.pending == nil,
              isRecording, sessionStart == promptedSessionStart else { return }

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
