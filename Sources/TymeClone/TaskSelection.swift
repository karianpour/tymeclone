import Foundation

struct TaskNameParts: Equatable {
    let project: String
    let task: String

    init(_ name: String) {
        if let colon = name.firstIndex(of: ":") {
            let project = String(name[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let task = String(name[name.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !project.isEmpty && !task.isEmpty {
                self.project = project
                self.task = task
                return
            }
        }
        project = ""
        task = name
    }
}

struct TaskHistory {
    private(set) var names: [String]

    init(names: [String] = []) {
        self.names = Self.unique(names)
    }

    var recentTasks: [String] { Array(names.prefix(5)) }

    var recentProjects: [String] {
        Array(Self.unique(names.map { TaskNameParts($0).project }).prefix(5))
    }

    func tasks(for project: String) -> [String] {
        let project = project.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array(Self.unique(names.compactMap { name in
            let parts = TaskNameParts(name)
            return parts.project == project ? parts.task : nil
        }).prefix(10))
    }

    mutating func remember(_ name: String) {
        names = Self.unique([name] + names)
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted
        }
    }
}

// A dialog edits only this draft. The timer and history change after Set succeeds.
struct TaskNameDraft {
    private(set) var fullName = ""
    private(set) var project = ""
    private(set) var task = ""

    init(fullName: String) {
        editFullName(fullName)
    }

    mutating func editFullName(_ name: String) {
        fullName = name
        // Recognize an unfinished "Project:" so Set stays disabled until a task
        // is entered, while preserving standalone names and additional colons.
        if let colon = name.firstIndex(of: ":"),
           !name[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            project = name[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            task = name[name.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            project = ""
            task = name
        }
    }

    mutating func editParts(project: String, task: String) {
        self.project = project
        self.task = task
        let project = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        fullName = project.isEmpty ? task : "\(project): \(task)"
    }

    var validationMessage: String? {
        if project.contains(":") { return "Use a project name without a colon; the colon separates project and task." }
        if !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a task for this project."
        }
        return nil
    }

    var confirmedName: String? {
        guard validationMessage == nil else { return nil }
        let entered = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return entered.isEmpty ? "Unnamed task" : entered
    }
}
