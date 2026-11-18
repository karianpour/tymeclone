import Foundation

// Keep overlapping lock/sleep/session events from producing duplicate stops or prompts.
struct AutomaticStopState {
    enum Absence: Hashable {
        case sleep, lock, inactiveSession

        var description: String {
            switch self {
            case .sleep: return "your Mac went to sleep"
            case .lock: return "your Mac was locked"
            case .inactiveSession: return "your user session became inactive"
            }
        }
    }

    struct PendingStop {
        let date: Date
        let reason: Absence
    }

    private(set) var absences: Set<Absence> = []
    private(set) var pending: PendingStop?
    var isAway: Bool { !absences.isEmpty }
    var shouldPrompt: Bool { !isAway && pending != nil }

    mutating func leave(_ reason: Absence, recording: Bool, at date: Date) {
        absences.insert(reason)
        if recording && pending == nil {
            pending = PendingStop(date: date, reason: reason)
        }
    }

    mutating func returnFrom(_ reason: Absence) {
        absences.remove(reason)
    }

    mutating func acknowledge() {
        pending = nil
    }
}
