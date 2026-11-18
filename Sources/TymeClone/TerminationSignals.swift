import Foundation
import Darwin

// Dispatch delivers catchable termination requests on the main queue, where it is
// safe to save files and ask AppKit to quit. Never do this work in a POSIX handler.
final class TerminationSignals {
    private var sources: [DispatchSourceSignal] = []

    init(onRequest: @escaping () -> Void) {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler(handler: onRequest)
            source.activate()
            sources.append(source)
        }
    }
}
