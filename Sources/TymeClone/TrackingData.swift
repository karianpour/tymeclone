import Foundation

struct RecordedSegment {
    let task: String
    let start: Date
    let end: Date
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

// Persist before changing state so a failed save leaves the active timer intact.
struct TaskTimer {
    private(set) var taskName: String
    private(set) var startedAt: Date?

    mutating func start(at date: Date) {
        startedAt = date
    }

    mutating func stop(at date: Date, save: (RecordedSegment) throws -> Void) throws -> RecordedSegment? {
        guard let start = startedAt else { return nil }
        let segment = RecordedSegment(task: taskName, start: start, end: max(start, date))
        try save(segment)
        startedAt = nil
        return segment
    }

    mutating func setTask(_ name: String, at date: Date, save: (RecordedSegment) throws -> Void) throws {
        guard name != taskName else { return }
        if startedAt != nil {
            let segment = try stop(at: date, save: save)
            startedAt = segment?.end
        }
        taskName = name
    }
}

func saveSegment(_ segment: RecordedSegment) throws {
    try appendSegmentToCSV(task: segment.task, start: segment.start, end: segment.end, duration: segment.duration)
}

func formatDuration(_ seconds: TimeInterval, includeSeconds: Bool = true) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return includeSeconds ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", h, m)
}

func formatClock(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
}

func formatDateTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: date)
}

// Resolved at runtime from the current user's home directory, so the default
// works on any machine - unlike a path baked in at compile time via #filePath.
let defaultOutputFolder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents")
    .appendingPathComponent("TymeClone")
let outputFolderDefaultsKey = "OutputFolder"
let lastTaskNameDefaultsKey = "LastTaskName"

func currentOutputFolder() -> URL {
    if let custom = UserDefaults.standard.string(forKey: outputFolderDefaultsKey), !custom.isEmpty {
        return URL(fileURLWithPath: custom)
    }
    return defaultOutputFolder
}

// Quotes a CSV field if it contains characters that would otherwise break column parsing.
func csvField(_ value: String) -> String {
    guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
        return value
    }
    return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}

// Parse whole records so quoted newlines remain part of the task name.
func parseCSV(_ text: String) -> [[String]] {
    var records: [[String]] = []
    var fields: [String] = []
    var current = ""
    var insideQuotes = false
    let chars = Array(text)
    var i = 0
    while i < chars.count {
        let char = chars[i]
        if insideQuotes {
            if char == "\"" {
                if i + 1 < chars.count && chars[i + 1] == "\"" {
                    current.append("\"")
                    i += 1
                } else {
                    insideQuotes = false
                }
            } else {
                current.append(char)
            }
        } else if char == "\"" {
            insideQuotes = true
        } else if char == "," {
            fields.append(current)
            current = ""
        } else if char == "\n" || char == "\r" || char == "\r\n" {
            fields.append(current)
            if fields.contains(where: { !$0.isEmpty }) { records.append(fields) }
            fields = []
            current = ""
        } else {
            current.append(char)
        }
        i += 1
    }
    if !current.isEmpty || !fields.isEmpty {
        fields.append(current)
        records.append(fields)
    }
    return records
}

func recentTaskNames(from names: [String]) -> [String] {
    var seen = Set<String>()
    return Array(names.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted }.prefix(5))
}

// Rebuild from disk on every launch so edits and migrations replace old names.
func recordedRecentTaskNames(folder: URL = currentOutputFolder()) -> [String] {
    let csv = (try? String(contentsOf: folder.appendingPathComponent("segments.csv"), encoding: .utf8)) ?? ""
    let recorded = parseCSV(csv).dropFirst().reversed().compactMap { $0.count == 4 ? $0[0] : nil }
    return recentTaskNames(from: recorded)
}

// Base64 keeps CSV text (including </script> and Unicode) out of executable HTML.
func makeReportHTML(folder: URL, generatedAt: Date = Date()) throws -> String {
    let csvURL = folder.appendingPathComponent("segments.csv")
    var snapshot = ["source": csvURL.path, "generatedAt": ISO8601DateFormatter().string(from: generatedAt)]
    do {
        snapshot["csv"] = try String(contentsOf: csvURL, encoding: .utf8)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        snapshot["message"] = "No saved segments yet. Stop a recording, then choose Open Report again."
    } catch {
        snapshot["message"] = "Could not read segments.csv: \(error.localizedDescription)"
    }
    let encoded = try JSONSerialization.data(withJSONObject: snapshot).base64EncodedString()
    return reportHTMLTemplate.replacingOccurrences(of: "__TYMECLONE_SNAPSHOT__", with: encoded)
}

func writeReportHTML() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TymeClone", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("report.html")
    try makeReportHTML(folder: currentOutputFolder()).write(to: fileURL, atomically: true, encoding: .utf8)
    return fileURL
}

func appendSegmentToCSV(task: String, start: Date, end: Date, duration: TimeInterval, folder: URL = currentOutputFolder()) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fileURL = folder.appendingPathComponent("segments.csv")
    let line = "\(csvField(task)),\(formatDateTime(start)),\(formatDateTime(end)),\(formatDuration(duration))\n"

    var data: Data
    do {
        data = try Data(contentsOf: fileURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        data = Data()
    }
    if data.isEmpty { data = Data("Task,Start,End,Duration\n".utf8) }
    if data.last != 10 && data.last != 13 { data.append(10) }
    data.append(contentsOf: line.utf8)
    // An atomic replacement preserves the old CSV if writing the new data fails.
    try data.write(to: fileURL, options: .atomic)
}

// Sums the Duration of every segments.csv row matching the given task name.
func totalDuration(forTask task: String, folder: URL = currentOutputFolder()) -> TimeInterval {
    let segmentsURL = folder.appendingPathComponent("segments.csv")
    guard let content = try? String(contentsOf: segmentsURL, encoding: .utf8) else {
        return 0
    }

    var total: TimeInterval = 0
    for columns in parseCSV(content).dropFirst() {
        guard columns.count == 4, columns[0] == task else { continue }
        total += parseDuration(columns[3])
    }
    return total
}

func parseDuration(_ text: String) -> TimeInterval {
    let parts = text.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 3 else { return 0 }
    return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
}

enum ExportError: Error {
    case noSegmentsFile
}

// Groups segments.csv by the Start date and writes the per-day totals to daily_summary.csv.
func exportDailySummary(folder: URL = currentOutputFolder()) throws -> URL {
    let segmentsURL = folder.appendingPathComponent("segments.csv")
    guard FileManager.default.fileExists(atPath: segmentsURL.path) else {
        throw ExportError.noSegmentsFile
    }

    let content = try String(contentsOf: segmentsURL, encoding: .utf8)
    var totalsByDate: [String: TimeInterval] = [:]

    for columns in parseCSV(content).dropFirst() {
        guard columns.count == 4 else { continue }
        let date = String(columns[1].prefix(10))
        totalsByDate[date, default: 0] += parseDuration(columns[3])
    }

    var output = "Date,Total Duration\n"
    for date in totalsByDate.keys.sorted() {
        output += "\(date),\(formatDuration(totalsByDate[date]!))\n"
    }

    let summaryURL = folder.appendingPathComponent("daily_summary.csv")
    try output.write(to: summaryURL, atomically: true, encoding: .utf8)
    return summaryURL
}

