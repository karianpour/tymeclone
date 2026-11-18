# TymeClone

A tiny macOS menu bar timer that reproduces the one feature from [Tyme 2](https://www.tyme-app.com) worth keeping around after its development stopped: automatic idle detection with a prompt to keep, split, or stop the running timer.

## Features

- Menu bar timer with Start/Stop recording, tagged with a free-text task name
- Visible recent-task list rebuilt from the last five distinct tasks in `segments.csv` on every startup
- Synchronized full-name input and editable Project/Task fields, with five recent projects and ten recent tasks per project
- Change tasks while recording to save the previous segment and continue under the new task
- Optional `Project: Task` naming for project totals without changing the CSV format
- A red dot (● recording) or black square (■ idle) status icon, plus a jitter-free monospaced elapsed time
- Idle detection via macOS' native `HIDIdleTime` (the same signal used for screensaver/display sleep) — no accessibility permissions required
- When the configured idle threshold is exceeded, a popup offers three choices:
  - **Keep Running** — count the idle time as work
  - **Split Here** — end the current segment at the last-active timestamp and start a new one now, keeping the same task
  - **Stop** — end the current segment at the last-active timestamp and stop recording
- Automatically saves and stops an active recording when the Mac locks, sleeps (including lid closure that causes sleep), or switches away from your user session. On return, **Start Recording** starts a fresh segment for the same task; **Keep Stopped** dismisses the dialog. If recording was already stopped, no dialog appears. Overlapping lock/sleep events produce a single prompt, after waking and unlocking.
- Configurable idle threshold (1/3/5/10/15 min)
- "Show Seconds" toggle for the menu bar display
- Read-only "Task Total" menu entry showing the summed time for the current task across all recorded segments, live while recording
- Normal Quit, Terminal `kill <pid>` (SIGTERM), and Ctrl+C (SIGINT) save the current recording before exiting. If saving fails, the app stays open and shows an error. Force Quit and `kill -9` cannot save at termination; the next launch offers recovery from the last checkpoint.
- Recovery information is saved immediately on Start and checkpointed every **2 minutes**, including while menus or dialogs are open. After an unexpected exit, choose **Recover Recording**, **Adjust End Time…**, or **Discard Recording**. Recovery leaves recording stopped and does not count time while the app was closed.
- Every finished segment is appended to a `segments.csv` file, one row per segment
- Configurable output folder (defaults to `~/Documents/TymeClone`, resolved at runtime so it works on any machine), with Reveal in Finder
- "Export Daily Summary…" writes a `daily_summary.csv` with per-day totals
- "Open Report" opens a self-contained `report.html` with your saved segments already loaded: totals by project, task, and day, a full segment table, and "Export as PDF" (uses the browser's print-to-PDF)

## Requirements

- macOS 13 or later
- Swift toolchain (Xcode Command Line Tools are enough: `xcode-select --install`)

## Build & Run

```bash
swift run
```

or build a standalone binary:

```bash
swift build -c release
./.build/release/TymeClone
```

The app runs as a menu bar accessory (no Dock icon). Look for the status icon (● or ■) — if your menu bar is full, hold **Cmd** and drag icons around to reveal it.

### Launching by double-click

A bare command-line binary usually opens in a Terminal window when double-clicked in Finder. To get a proper double-clickable app instead:

```bash
./build-app.sh
```

This builds a release binary and wraps it into `TymeClone.app` (ad-hoc signed, `LSUIElement` so it stays a menu-bar-only app with no Dock icon). Double-click `TymeClone.app` in Finder, or drag it into `/Applications`. Re-run the script after any code change to rebuild the bundle — `TymeClone.app` itself is gitignored, only `build-app.sh` is tracked.

To install it properly, copy the built bundle into `/Applications`:

```bash
cp -R TymeClone.app /Applications/
```

Since it's built locally (not downloaded), macOS won't set a quarantine flag, so Gatekeeper won't complain on first launch. To start it automatically at login, add it in **System Settings → General → Login Items** after copying it to `/Applications`. There's no auto-update mechanism — after a code change, rebuild with `./build-app.sh` and copy it over again.

## Usage

Click the status icon in the menu bar:

- **Start/Stop Recording** — toggles the timer for the current task
- **Set task (…)** — edit the full task name, choose a row from the visible five-task recent list, or use the editable **Project** and **Task** fields below it. Project offers the last five distinct projects; Task offers the last ten distinct tasks for the entered project. All fields stay synchronized, and changing projects preserves the typed task while updating suggestions. Selection fills the fields; **Set** confirms and **Cancel** changes nothing. A project requires a task, and project names cannot contain the separating colon. Leave Project blank for a standalone task; an entirely empty name falls back to "Unnamed task". While recording, setting a different task saves the old segment and starts the new one at the same timestamp. If saving fails, the original timer keeps running and an error is shown
- **Task Total: …** — read-only, shows the total time recorded for the current task (sum of all matching `segments.csv` rows, plus the running elapsed time while recording)
- **Idle Threshold** — how long the Mac must be idle before the popup appears
- **Show Seconds** — toggle seconds in the menu bar display
- **Output Folder** — shows the current CSV location; "Choose Output Folder…" picks a custom folder, "Use Default Location" resets to `~/Documents/TymeClone`. **Reveal in Finder** selects `segments.csv` if present, otherwise reveals the output folder (creating it if needed)
- **Export Daily Summary…** — aggregates `segments.csv` by day into `daily_summary.csv` in the same folder
- **Open Report** — generates `TymeClone/report.html` in your system temp directory, embeds the current saved CSV, and opens it in your default browser. Choose it again to refresh; browser refresh alone retains the embedded snapshot

Task suggestions are rebuilt from the full `segments.csv` history on every startup and when changing output folders, reading the newest records first. The recent list shows five distinct full names, while project/task suggestions can include older history beyond those five rows. Confirmed names move to the front during the session; only recorded names return after restarting. The current task is remembered separately.

## Interrupted recording recovery

The recovery file is `~/Library/Application Support/TymeClone/recording-recovery.json`. It records a unique recording ID, task, start time, last checkpoint, and the output folder selected when recording started. Changing the output folder applies to subsequent recordings; an active or recovered segment stays with its original folder.

Start writes this file immediately and refuses to start if it cannot be saved. A checkpoint is written every two minutes while recording. On normal Stop, Quit, task switch, lock, or sleep, the exact end time is saved rather than waiting for a checkpoint. Successful saves remove the recovery file. Checkpoint failures preserve the previous checkpoint and report an error; corrupted recovery files are preserved and block a new recording until resolved.

On relaunch, an interrupted active recording offers **Recover Recording** through the last checkpoint, **Adjust End Time…** using a date/time picker, or **Discard Recording**. Discard immediately deletes the recovery information. Canceling the end-time picker returns to the recovery choice. There is no recovery menu or option to defer the decision. Recovery never starts a timer automatically. An end time must be between the recording's start and the current time. If the app was killed before its first checkpoint, the initial recovery has zero duration; use Adjust End Time to supply the missing time.

To prevent duplicate rows if the process dies during a save, a journal stores the intended CSV bytes before the atomic CSV replacement. On relaunch, a pending save is completed or recognized as already saved, then the journal is removed. If the CSV was independently changed, the app preserves both files and reports the conflict instead of overwriting it. The CSV format remains four columns.

Manual check: start a disposable task, wait for at least one two-minute checkpoint, Force Quit, and relaunch. Recover should save only through the displayed checkpoint. Also try Adjust End Time (including Cancel returning to the recovery choice) and Discard Recording. After discarding, relaunch and confirm there is no recovery prompt or recovery menu item. A normal stop or quit should leave no recovery prompt on relaunch.

## CSV format

`segments.csv` gets a header row on first write, then one row per finished segment:

```csv
Task,Start,End,Duration
Client Report,2026-07-31 09:00:12,2026-07-31 10:15:47,01:15:35
```

- `Task`: free text, quoted per standard CSV rules if it contains a comma, quote, or newline
- `Start` / `End`: `yyyy-MM-dd HH:mm:ss`
- `Duration`: `HH:mm:ss`

`daily_summary.csv` (written by "Export Daily Summary…") groups all segments by the `Start` date:

```csv
Date,Total Duration
2026-07-31,03:45:22
```

## HTML report

`report.html` is a static, self-contained page with no external requests or dependencies. Each **Open Report** action reads the current output folder and embeds a snapshot of `segments.csv`, safely encoded to preserve Unicode and special characters. The report lives in `TymeClone/report.html` under the system temporary directory.

The source path and snapshot time appear above the report. Only saved segments are included; stop the current recording to include it, then choose **Open Report** again. An already-open report does not update automatically. Missing data shows an empty-state message; unreadable files show the reason. You can still load another CSV using **Load different file**, drag-and-drop, or **Choose File…**. "Export as PDF" opens the browser's print dialog, where you can choose "Save as PDF".

### Monthly and yearly reports

The report defaults to the **latest month with recorded segments** in the loaded CSV. Choose **Monthly** and a month, or **Yearly** and a year; only periods present in the file are listed, newest first. **All time** shows the entire file. Loading a different CSV resets the selection to its latest month.

The selected period applies to every total, chart, and segment row. The period heading is included in PDF exports. Segments belong to their recorded local **Start** date, including segments crossing midnight, a month boundary, or a year boundary; their duration is not split between periods.

### Projects

Name tasks as `Project: Task`, for example `Orca: Fix checkout` and `Orca: Customer meeting`. The report splits at the first colon and trims spaces around both parts. Both parts must be nonempty; ordinary names such as `Admin` appear under **No project**.

The **By project** chart sums all tasks in each project. **By task** sorts projects alphabetically, then tasks by total duration descending within each project, using task name to break ties. Tasks without a project appear last. This order uses the selected report period and also applies to PDF exports. Full recorded names are retained so identical task descriptions in different projects stay separate. The segment table shows Project and Task columns. Existing names and the four-column CSV format are preserved; there is no migration or automatic renaming of past work.

## Checks

Run the native regression tests and the dependency-free report checks:

```sh
swift test
node --test Tests/report.test.cjs
python3 Tests/recovery_process_test.py
```

The recovery process check compiles a disposable helper using the production storage code, kills it with SIGKILL at three save stages, and verifies recovery happens exactly once. It does not touch your installed app or recordings.

The report checks exercise the actual embedded JavaScript with a minimal DOM harness. For a manual UI check, launch the app and confirm that clicking a recent row fills all fields without applying it, Project and Task accept both typed text and dropdown choices, changing projects refreshes task suggestions, **Set** is disabled for a project without a task, **Cancel** changes nothing, switching during a recording saves time under the old name, **Reveal in Finder** selects the expected file, and **Open Report** displays saved data immediately. Also check PDF export in your browser. For automatic stops, test lock/unlock, sleep/wake, and lid close/open while recording: confirm one saved segment ending at departure, one return dialog, and a new start time only after choosing Start Recording. Repeat with recording already stopped (no dialog), choose Keep Stopped (no restart), and lock while the idle or restart dialog is open. Lock detection uses macOS distributed screen-lock notifications; verify these on the target macOS version. If saving fails, the original recording is retained with its end time held at departure; an error appears on return and Stop Recording retries the save.

## Scope

This remains a focused menu bar timer. Project grouping is derived from task names; there is no project-management hierarchy or editing of past segments. Normal Quit saves a running recording automatically. Forced termination can lose time since the last successful checkpoint (normally less than two minutes; longer if the app was unresponsive or a checkpoint failed). The recovery dialog allows correcting the end time.

## Please note

This app is vibe coded with Claude.
