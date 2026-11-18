"""Exercise production recovery storage across real SIGKILL/relaunch boundaries.

Runs only disposable helper processes and temporary data, never the installed app.
"""
import csv
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
HARNESS = r'''
import Foundation
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let phase = CommandLine.arguments[2]
let store = RecordingRecovery(fileURL: folder.appendingPathComponent("recovery.json"))
let start = Date(timeIntervalSince1970: 1_700_000_000)
if phase == "recover" {
    try store.load()
    if let recording = store.recording {
        if recording.commit != nil { try store.finishSave() }
        else { try store.recover(endingAt: recording.checkpoint) }
    }
} else {
    try store.begin(task: "Force quit test", at: start, folder: folder)
    try store.checkpoint(at: start.addingTimeInterval(120))
    if phase != "checkpoint" {
        try store.prepareSave(endingAt: start.addingTimeInterval(173))
    }
    if phase == "csv-written" {
        try store.recording!.commit!.after.write(to: folder.appendingPathComponent("segments.csv"), options: .atomic)
    }
    try Data().write(to: folder.appendingPathComponent("ready"))
    RunLoop.main.run()
}
'''

with tempfile.TemporaryDirectory(prefix="tymeclone-force-quit-") as directory:
    temporary = Path(directory)
    main = temporary / "main.swift"
    main.write_text(HARNESS)
    binary = temporary / "recovery-check"
    sources = ["RecordingRecovery.swift", "TrackingData.swift", "TaskSelection.swift", "ReportHTML.swift"]
    subprocess.run([
        "swiftc", "-module-cache-path", str(ROOT / ".build/clang-cache"),
        *[str(ROOT / "Sources/TymeClone" / name) for name in sources],
        str(main), "-o", str(binary),
    ], check=True)
    for phase, expected in [("checkpoint", "00:02:00"), ("prepared", "00:02:53"), ("csv-written", "00:02:53")]:
        folder = temporary / phase
        folder.mkdir()
        process = subprocess.Popen([str(binary), str(folder), phase])
        try:
            deadline = time.monotonic() + 10
            while not (folder / "ready").exists():
                assert process.poll() is None and time.monotonic() < deadline, "Helper did not become ready"
                time.sleep(0.02)
            process.send_signal(signal.SIGKILL)
            assert process.wait(timeout=10) == -signal.SIGKILL
            subprocess.run([str(binary), str(folder), "recover"], check=True, timeout=10)
            # A second launch must not add the recording again.
            subprocess.run([str(binary), str(folder), "recover"], check=True, timeout=10)
            with (folder / "segments.csv").open() as stream:
                rows = list(csv.reader(stream))
            assert len(rows) == 2 and rows[1][0] == "Force quit test", rows
            assert rows[1][3] == expected, rows
            assert not (folder / "recovery.json").exists()
            print(f"SIGKILL at {phase}: recovered {expected} exactly once")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
