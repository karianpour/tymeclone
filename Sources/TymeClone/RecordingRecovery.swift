import Foundation

struct RecoveryRecording: Codable {
    let id: UUID
    let task: String
    let start: Date
    var checkpoint: Date
    let outputFolder: URL
    var commit: RecoveryCommit?
}

struct RecoveryCommit: Codable {
    let end: Date
    let before: Data
    let after: Data
}

enum RecoveryError: LocalizedError {
    case unresolved, changedCSV, invalidEnd
    var errorDescription: String? {
        switch self {
        case .unresolved: return "Resolve the interrupted recording before starting another recording."
        case .changedCSV: return "segments.csv changed during an unfinished save. The recovery file has been preserved to avoid overwriting your data."
        case .invalidEnd: return "The end time must be between the recording's start and the current time."
        }
    }
}

// A write-ahead journal keeps the existing four-column CSV format. The exact
// before/after bytes distinguish an interrupted write from an already saved row.
final class RecordingRecovery {
    static let checkpointInterval: TimeInterval = 120
    let fileURL: URL
    private(set) var recording: RecoveryRecording?

    init(fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TymeClone/recording-recovery.json")) {
        self.fileURL = fileURL
    }

    func load() throws {
        do {
            recording = try JSONDecoder().decode(RecoveryRecording.self, from: Data(contentsOf: fileURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            recording = nil
        }
    }

    private func write(_ value: RecoveryRecording) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: fileURL, options: .atomic)
        recording = value
    }

    func begin(task: String, at date: Date, folder: URL) throws {
        try load()
        guard recording == nil else { throw RecoveryError.unresolved }
        try write(RecoveryRecording(id: UUID(), task: task, start: date, checkpoint: date, outputFolder: folder))
    }

    func checkpoint(at date: Date) throws {
        guard var value = recording, value.commit == nil,
              date.timeIntervalSince(value.checkpoint) >= Self.checkpointInterval else { return }
        value.checkpoint = date
        try write(value)
    }

    func discard() throws {
        do { try FileManager.default.removeItem(at: fileURL) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        recording = nil
    }

    private func csvData(at url: URL) throws -> Data {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return Data() }
    }

    // Persist the intended stop before touching the CSV. A retry always uses the
    // original stop time, including when the CSV succeeded but journal removal failed.
    func prepareSave(endingAt date: Date) throws {
        guard var value = recording else { throw RecoveryError.unresolved }
        guard value.commit == nil else { return }
        let end = max(value.start, date)
        let before = try csvData(at: value.outputFolder.appendingPathComponent("segments.csv"))
        var after = before
        if after.isEmpty { after = Data("Task,Start,End,Duration\n".utf8) }
        if after.last != 10 && after.last != 13 { after.append(10) }
        let line = "\(csvField(value.task)),\(formatDateTime(value.start)),\(formatDateTime(end)),\(formatDuration(end.timeIntervalSince(value.start)))\n"
        after.append(contentsOf: line.utf8)
        value.checkpoint = end
        value.commit = RecoveryCommit(end: end, before: before, after: after)
        try write(value)
    }

    func finishSave() throws {
        guard let value = recording, let commit = value.commit else { throw RecoveryError.unresolved }
        let csvURL = value.outputFolder.appendingPathComponent("segments.csv")
        let current = try csvData(at: csvURL)
        if current != commit.after {
            guard current == commit.before else { throw RecoveryError.changedCSV }
            try FileManager.default.createDirectory(at: value.outputFolder, withIntermediateDirectories: true)
            try commit.after.write(to: csvURL, options: .atomic)
        }
        try discard()
    }

    func save(endingAt date: Date) throws {
        try prepareSave(endingAt: date)
        try finishSave()
    }

    func recover(endingAt date: Date, now: Date = Date()) throws {
        guard let value = recording else { throw RecoveryError.unresolved }
        guard date >= value.start, date <= now else { throw RecoveryError.invalidEnd }
        try save(endingAt: date)
    }
}
