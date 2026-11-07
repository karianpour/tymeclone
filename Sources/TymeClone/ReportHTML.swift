// Self-contained offline report, populated with a base64-encoded JSON snapshot.
// Kept as a raw string literal (`#"""..."""#`) so JS regex escapes like \r\n
// pass through untouched instead of being interpreted as Swift escapes.
let reportHTMLTemplate = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>TymeClone Report</title>
<style>
  :root {
    color-scheme: light dark;
    --surface-1: #fcfcfb;
    --page-plane: #f9f9f7;
    --text-primary: #0b0b0b;
    --text-secondary: #52514e;
    --text-muted: #898781;
    --gridline: #e1e0d9;
    --baseline: #c3c2b7;
    --series-1: #2a78d6;
    --border: rgba(11, 11, 11, 0.10);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --surface-1: #1a1a19;
      --page-plane: #0d0d0d;
      --text-primary: #ffffff;
      --text-secondary: #c3c2b7;
      --text-muted: #898781;
      --gridline: #2c2c2a;
      --baseline: #383835;
      --series-1: #3987e5;
      --border: rgba(255, 255, 255, 0.10);
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--page-plane);
    color: var(--text-primary);
    font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
  }
  .viz-root { max-width: 900px; margin: 0 auto; padding: 32px 24px 64px; }

  .page-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 24px; gap: 12px; flex-wrap: wrap; }
  .page-header h1 { font-size: 20px; margin: 0; }
  .header-actions { display: flex; gap: 8px; }

  button { font: inherit; cursor: pointer; border-radius: 8px; padding: 8px 16px; border: 1px solid var(--border); background: var(--surface-1); color: var(--text-primary); }
  button:hover { filter: brightness(0.97); }
  .btn-primary { background: var(--series-1); color: #fff; border-color: transparent; }
  .btn-primary:hover { filter: brightness(1.08); }

  .dropzone { border: 2px dashed var(--baseline); border-radius: 12px; padding: 48px 24px; text-align: center; color: var(--text-secondary); margin-bottom: 32px; transition: border-color .15s ease, background .15s ease; }
  .dropzone.dragover { border-color: var(--series-1); background: rgba(42, 120, 214, 0.08); }
  .dropzone p { margin: 0 0 12px; }
  .load-error { color: #d03b3b; margin-top: 16px !important; font-size: 14px; }
  .source-info { font-size: 13px; color: var(--text-secondary); overflow-wrap: anywhere; white-space: pre-line; margin-bottom: 24px; }
  .report-filters { display: flex; align-items: end; flex-wrap: wrap; gap: 16px; margin-bottom: 20px; }
  .report-filters label { display: block; font-size: 13px; color: var(--text-secondary); margin-bottom: 6px; }
  .report-filters select { font: inherit; border: 1px solid var(--border); border-radius: 8px; padding: 8px 12px; background: var(--surface-1); color: var(--text-primary); min-width: 160px; }
  .period-heading { font-size: 18px; font-weight: 600; margin: 0 0 16px; }

  .hero-section { display: grid; grid-template-columns: 2fr 1fr 1fr 1fr; gap: 12px; margin-bottom: 32px; }
  .stat-tile { background: var(--surface-1); border: 1px solid var(--border); border-radius: 12px; padding: 16px 20px; display: flex; flex-direction: column; gap: 4px; justify-content: center; }
  .stat-label { font-size: 13px; color: var(--text-secondary); }
  .stat-value { font-size: 22px; font-weight: 600; color: var(--text-primary); font-variant-numeric: tabular-nums; }
  .hero-value { font-size: 48px; font-variant-numeric: normal; line-height: 1.1; }

  .chart-section { margin-bottom: 32px; }
  .chart-section h2 { font-size: 15px; color: var(--text-secondary); font-weight: 600; margin: 0 0 12px; }
  .bar-list { display: flex; flex-direction: column; gap: 8px; max-height: 360px; overflow-y: auto; padding-right: 4px; }
  .bar-row { display: grid; grid-template-columns: 140px 1fr 72px; align-items: center; gap: 12px; }
  .bar-label { font-size: 13px; color: var(--text-secondary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .bar-track { position: relative; height: 24px; background: var(--gridline); border-radius: 4px; overflow: hidden; }
  .bar-fill { position: absolute; top: 0; left: 0; height: 100%; background: var(--series-1); border-radius: 0 4px 4px 0; }
  .bar-value { font-size: 13px; color: var(--text-primary); font-variant-numeric: tabular-nums; text-align: right; }

  .table-section h2 { font-size: 15px; color: var(--text-secondary); font-weight: 600; margin: 0 0 12px; }
  .table-scroll { max-height: 400px; overflow: auto; border: 1px solid var(--border); border-radius: 8px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--gridline); font-variant-numeric: tabular-nums; white-space: nowrap; }
  th { color: var(--text-secondary); font-weight: 600; position: sticky; top: 0; background: var(--surface-1); }

  .report-meta { margin-top: 24px; font-size: 12px; color: var(--text-muted); }

  @media print {
    :root {
      --surface-1: #fcfcfb; --page-plane: #ffffff; --text-primary: #0b0b0b;
      --text-secondary: #52514e; --text-muted: #898781; --gridline: #e1e0d9;
      --baseline: #c3c2b7; --series-1: #2a78d6; --border: rgba(11, 11, 11, 0.10);
    }
    .no-print { display: none !important; }
    .viz-root { max-width: none; padding: 0; }
    .bar-list, .table-scroll { max-height: none; overflow: visible; }
  }
</style>
</head>
<body>
<div class="viz-root">

  <header class="page-header">
    <h1>TymeClone Report</h1>
    <div class="header-actions no-print">
      <button id="loadBtn">Load different file</button>
      <button id="printBtn" class="btn-primary">Export as PDF</button>
    </div>
  </header>

  <p id="sourceInfo" class="source-info"></p>
  <div id="dropzone" class="dropzone no-print">
    <p id="loadStatus" role="status" hidden></p>
    <p>Drop <code>segments.csv</code> here, or</p>
    <button id="pickBtn" class="btn-primary">Choose File…</button>
    <input type="file" id="fileInput" accept=".csv" hidden>
    <p id="loadError" class="load-error" role="alert" hidden></p>
  </div>

  <main id="report" hidden>
    <div class="report-filters no-print">
      <div>
        <label for="periodMode">Report</label>
        <select id="periodMode">
          <option value="month">Monthly</option>
          <option value="year">Yearly</option>
          <option value="all">All time</option>
        </select>
      </div>
      <div id="periodChoice">
        <label for="periodValue" id="periodLabel">Month</label>
        <select id="periodValue"></select>
      </div>
    </div>
    <h2 id="periodHeading" class="period-heading" aria-live="polite"></h2>
    <section class="hero-section">
      <div class="stat-tile">
        <span class="stat-label">Total tracked time</span>
        <span class="stat-value hero-value" id="heroTotal">—</span>
      </div>
      <div class="stat-tile">
        <span class="stat-label">Segments</span>
        <span class="stat-value" id="statSegments">—</span>
      </div>
      <div class="stat-tile">
        <span class="stat-label">Tasks</span>
        <span class="stat-value" id="statTasks">—</span>
      </div>
      <div class="stat-tile">
        <span class="stat-label">Date range</span>
        <span class="stat-value" id="statRange">—</span>
      </div>
    </section>

    <section class="chart-section">
      <h2>By project</h2>
      <div class="bar-list" id="projectBars"></div>
    </section>

    <section class="chart-section">
      <h2>By task</h2>
      <div class="bar-list" id="taskBars"></div>
    </section>

    <section class="chart-section">
      <h2>By day</h2>
      <div class="bar-list" id="dayBars"></div>
    </section>

    <section class="table-section">
      <h2>Segments</h2>
      <div class="table-scroll">
        <table id="segmentsTable">
          <thead><tr><th>Project</th><th>Task</th><th>Start</th><th>End</th><th>Duration</th></tr></thead>
          <tbody></tbody>
        </table>
      </div>
    </section>

    <p class="report-meta" id="reportMeta"></p>
  </main>

</div>

<script type="application/octet-stream" id="snapshotData">__TYMECLONE_SNAPSHOT__</script>
<script>
(function () {
  var dropzone = document.getElementById('dropzone');
  var fileInput = document.getElementById('fileInput');
  var pickBtn = document.getElementById('pickBtn');
  var loadBtn = document.getElementById('loadBtn');
  var printBtn = document.getElementById('printBtn');
  var loadError = document.getElementById('loadError');
  var report = document.getElementById('report');
  var loadStatus = document.getElementById('loadStatus');
  var sourceInfo = document.getElementById('sourceInfo');
  var sourceDescription = '';
  var periodMode = document.getElementById('periodMode');
  var periodValue = document.getElementById('periodValue');
  var allRows = [];
  var availableMonths = [];
  var availableYears = [];

  function monthForStart(start) {
    // Use the recorded local start date, without timezone conversion. As with
    // daily exports, a segment crossing a boundary belongs to its start date.
    var match = /^(\d{4})-(\d{2})-(\d{2})(?: |T|$)/.exec(start);
    if (!match) return null;
    var year = Number(match[1]);
    var month = Number(match[2]);
    var day = Number(match[3]);
    var leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
    var days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if (year < 1 || month < 1 || month > 12 || day < 1 || day > days[month - 1]) return null;
    return match[1] + '-' + match[2];
  }

  function monthLabel(key) {
    var names = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    return names[Number(key.slice(5, 7)) - 1] + ' ' + key.slice(0, 4);
  }

  function updatePeriodOptions(preferred) {
    var yearly = periodMode.value === 'year';
    var periods = yearly ? availableYears : availableMonths;
    document.getElementById('periodChoice').hidden = periodMode.value === 'all';
    document.getElementById('periodLabel').textContent = yearly ? 'Year' : 'Month';
    periodValue.innerHTML = '';
    periods.forEach(function (key) {
      var option = document.createElement('option');
      option.value = key;
      option.textContent = yearly ? key : monthLabel(key);
      periodValue.appendChild(option);
    });
    // Keep the same year when switching between monthly and yearly views.
    periodValue.value = periods.find(function (key) { return key === preferred; }) ||
      periods.find(function (key) { return preferred && key.slice(0, 4) === preferred.slice(0, 4); }) || periods[0] || '';
  }

  function renderSelectedPeriod() {
    var mode = periodMode.value;
    var selected = periodValue.value;
    var label = mode === 'all' ? 'All time' : (mode === 'year' ? selected : monthLabel(selected));
    document.getElementById('periodHeading').textContent = label;
    var rows = allRows.filter(function (row) {
      return mode === 'all' || (mode === 'year' ? row.month.slice(0, 4) : row.month) === selected;
    });
    render(rows);
    document.getElementById('reportMeta').textContent = label + ' · ' + sourceDescription;
  }

  function parseCSVRecords(text) {
    var records = [];
    var fields = [];
    var current = '';
    var insideQuotes = false;
    for (var i = 0; i < text.length; i++) {
      var char = text[i];
      if (insideQuotes) {
        if (char === '"') {
          if (text[i + 1] === '"') { current += '"'; i++; }
          else { insideQuotes = false; }
        } else {
          current += char;
        }
      } else if (char === '"') {
        insideQuotes = true;
      } else if (char === ',') {
        fields.push(current);
        current = '';
      } else if (char === '\r' || char === '\n') {
        fields.push(current);
        if (fields.some(function (field) { return field.length > 0; })) records.push(fields);
        fields = [];
        current = '';
        if (char === '\r' && text[i + 1] === '\n') i++;
      } else {
        current += char;
      }
    }
    if (insideQuotes) throw new Error('The CSV contains an unfinished quoted field.');
    if (current.length || fields.length) {
      fields.push(current);
      records.push(fields);
    }
    return records;
  }

  function parseDurationToSeconds(text) {
    var parts = text.split(':').map(Number);
    if (parts.length !== 3 || parts.some(isNaN)) return 0;
    return parts[0] * 3600 + parts[1] * 60 + parts[2];
  }

  function formatHMS(totalSeconds) {
    var s = Math.round(totalSeconds);
    var h = Math.floor(s / 3600);
    var m = Math.floor((s % 3600) / 60);
    var sec = s % 60;
    return String(h).padStart(2, '0') + ':' + String(m).padStart(2, '0') + ':' + String(sec).padStart(2, '0');
  }

  function formatCompact(totalSeconds) {
    var s = Math.round(totalSeconds);
    var h = Math.floor(s / 3600);
    var m = Math.floor((s % 3600) / 60);
    if (h === 0) return m + 'm';
    return h + 'h ' + m + 'm';
  }

  function escapeHTML(str) {
    var div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
  }

  function parseCSV(text) {
    var records = parseCSVRecords(text);
    if (records.length === 0) return [];
    var header = records[0].map(function (h) { return h.trim(); });
    var taskIdx = header.indexOf('Task');
    var startIdx = header.indexOf('Start');
    var endIdx = header.indexOf('End');
    var durationIdx = header.indexOf('Duration');
    if (taskIdx === -1 || startIdx === -1 || endIdx === -1 || durationIdx === -1) {
      throw new Error("This doesn't look like a segments.csv – missing Task/Start/End/Duration columns.");
    }

    var rows = [];
    for (var i = 1; i < records.length; i++) {
      var cols = records[i];
      if (cols.length <= Math.max(taskIdx, startIdx, endIdx, durationIdx)) continue;
      var month = monthForStart(cols[startIdx]);
      if (!month) throw new Error('Invalid Start date in CSV record ' + (i + 1) + '. Expected YYYY-MM-DD HH:mm:ss.');
      rows.push({
        task: cols[taskIdx],
        start: cols[startIdx],
        end: cols[endIdx],
        durationSeconds: parseDurationToSeconds(cols[durationIdx]),
        month: month
      });
    }
    return rows;
  }

  function projectForTask(name) {
    var separator = name.indexOf(':');
    var project = separator > 0 ? name.slice(0, separator).trim() : '';
    var task = separator > 0 ? name.slice(separator + 1).trim() : '';
    // Require both parts; an ordinary name ending in ':' stays ungrouped.
    return project && task ? { project: project, task: task } : { project: null, task: name };
  }

  function renderBars(containerId, entries) {
    var container = document.getElementById(containerId);
    container.innerHTML = '';
    var max = 1;
    entries.forEach(function (e) { if (e[1] > max) max = e[1]; });
    entries.forEach(function (entry) {
      var label = entry[0];
      var seconds = entry[1];
      var row = document.createElement('div');
      row.className = 'bar-row';
      var pct = Math.max((seconds / max) * 100, 2);
      row.title = label + ' — ' + formatHMS(seconds);
      row.innerHTML =
        '<span class="bar-label">' + escapeHTML(label) + '</span>' +
        '<div class="bar-track"><div class="bar-fill" style="width:' + pct + '%"></div></div>' +
        '<span class="bar-value">' + formatCompact(seconds) + '</span>';
      container.appendChild(row);
    });
  }

  function render(rows) {
    if (rows.length === 0) {
      showStatus('No saved segments yet. Stop a recording, then choose Open Report again.');
      return;
    }

    var totalSeconds = 0;
    var byTask = new Map();
    var byProject = new Map();
    var byDate = new Map();
    rows.forEach(function (r) {
      totalSeconds += r.durationSeconds;
      byTask.set(r.task, (byTask.get(r.task) || 0) + r.durationSeconds);
      var project = projectForTask(r.task).project;
      byProject.set(project, (byProject.get(project) || 0) + r.durationSeconds);
      var date = r.start.slice(0, 10);
      byDate.set(date, (byDate.get(date) || 0) + r.durationSeconds);
    });

    var taskEntries = Array.from(byTask.entries()).sort(function (a, b) { return b[1] - a[1]; });
    var projectEntries = Array.from(byProject.entries()).sort(function (a, b) { return b[1] - a[1]; }).map(function (entry) {
      return [entry[0] === null ? 'No project' : entry[0], entry[1]];
    });
    var dateEntries = Array.from(byDate.entries()).sort(function (a, b) { return b[0].localeCompare(a[0]); });
    var dates = Array.from(byDate.keys()).sort();
    var dateRange = dates.length > 1 ? (dates[0] + ' → ' + dates[dates.length - 1]) : (dates[0] || '—');

    document.getElementById('heroTotal').textContent = formatCompact(totalSeconds);
    document.getElementById('statSegments').textContent = String(rows.length);
    document.getElementById('statTasks').textContent = String(byTask.size);
    document.getElementById('statRange').textContent = dateRange;

    renderBars('projectBars', projectEntries);
    renderBars('taskBars', taskEntries);
    renderBars('dayBars', dateEntries);

    var tbody = document.querySelector('#segmentsTable tbody');
    tbody.innerHTML = '';
    var sortedRows = rows.slice().sort(function (a, b) { return b.start.localeCompare(a.start); });
    sortedRows.forEach(function (r) {
      var tr = document.createElement('tr');
      var parts = projectForTask(r.task);
      tr.innerHTML = '<td>' + escapeHTML(parts.project === null ? 'No project' : parts.project) + '</td><td>' + escapeHTML(parts.task) + '</td><td>' + escapeHTML(r.start) + '</td><td>' + escapeHTML(r.end) + '</td><td>' + formatHMS(r.durationSeconds) + '</td>';
      tbody.appendChild(tr);
    });

    document.getElementById('reportMeta').textContent = sourceDescription;

    dropzone.hidden = true;
    report.hidden = false;
  }

  function showError(message) {
    loadStatus.hidden = true;
    loadError.textContent = message;
    loadError.hidden = false;
    dropzone.hidden = false;
    report.hidden = true;
  }

  function showStatus(message) {
    loadError.hidden = true;
    loadStatus.textContent = message;
    loadStatus.hidden = false;
    dropzone.hidden = false;
    report.hidden = true;
  }

  function loadCSVText(text) {
    try {
      loadError.hidden = true;
      loadStatus.hidden = true;
      allRows = parseCSV(text);
      availableMonths = Array.from(new Set(allRows.map(function (row) { return row.month; }))).sort().reverse();
      availableYears = Array.from(new Set(availableMonths.map(function (month) { return month.slice(0, 4); })));
      periodMode.value = 'month';
      updatePeriodOptions();
      if (allRows.length === 0) render([]);
      else renderSelectedPeriod();
    } catch (e) {
      showError(e.message);
    }
  }

  function loadFile(file) {
    var reader = new FileReader();
    reader.onload = function () {
      sourceDescription = 'File: ' + file.name + '\nLoaded ' + new Date().toLocaleString();
      sourceInfo.textContent = sourceDescription;
      loadCSVText(String(reader.result));
    };
    reader.onerror = function () { showError('Could not read that file.'); };
    reader.readAsText(file);
  }

  ['dragover', 'dragenter'].forEach(function (evt) {
    dropzone.addEventListener(evt, function (e) {
      e.preventDefault();
      dropzone.classList.add('dragover');
    });
  });
  ['dragleave', 'dragend'].forEach(function (evt) {
    dropzone.addEventListener(evt, function () { dropzone.classList.remove('dragover'); });
  });
  dropzone.addEventListener('drop', function (e) {
    e.preventDefault();
    dropzone.classList.remove('dragover');
    var file = e.dataTransfer.files[0];
    if (file) loadFile(file);
  });

  pickBtn.addEventListener('click', function () { fileInput.click(); });
  fileInput.addEventListener('change', function () {
    if (fileInput.files[0]) loadFile(fileInput.files[0]);
  });

  loadBtn.addEventListener('click', function () {
    dropzone.hidden = false;
    report.hidden = true;
    loadError.hidden = true;
    loadStatus.hidden = true;
  });

  printBtn.addEventListener('click', function () { window.print(); });
  periodMode.addEventListener('change', function () {
    updatePeriodOptions(periodValue.value);
    renderSelectedPeriod();
  });
  periodValue.addEventListener('change', renderSelectedPeriod);

  function loadSnapshot() {
    try {
      var encoded = document.getElementById('snapshotData').textContent.trim();
      var bytes = Uint8Array.from(atob(encoded), function (char) { return char.charCodeAt(0); });
      var snapshot = JSON.parse(new TextDecoder().decode(bytes));
      sourceDescription = 'Source: ' + snapshot.source + '\nSnapshot ' + new Date(snapshot.generatedAt).toLocaleString() + ' · Saved segments only';
      sourceInfo.textContent = sourceDescription + '\nChoose Open Report in the app again to refresh.';
      if (typeof snapshot.csv === 'string') loadCSVText(snapshot.csv);
      else showStatus(snapshot.message);
    } catch (error) {
      showError('Could not load the report snapshot. Choose a CSV file below.');
    }
  }

  loadSnapshot();
})();
</script>

</body>
</html>
"""#
