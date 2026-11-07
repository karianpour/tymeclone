const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const template = fs.readFileSync(path.join(__dirname, '../Sources/TymeClone/ReportHTML.swift'), 'utf8');
const script = template.match(/<script>\n([\s\S]*?)<\/script>/)[1];
const header = 'Task,Start,End,Duration\r\n';
const record = (task, duration, day = '2026-11-07') =>
  `"${task.replaceAll('"', '""')}",${day} 09:00:00,${day} 10:00:00,${duration}\r\n`;

// Only DOM primitives used by the report; all parsing and rendering comes from
// the real report script. This is a logic check, not a browser layout test.
class Element {
  constructor() {
    this.textContent = '';
    this.children = [];
    this.events = {};
    this.hidden = false;
    this.classList = { add() {}, remove() {} };
  }
  set innerHTML(value) { this.html = value; this.children = []; }
  get innerHTML() {
    return this.html ?? this.textContent.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  }
  appendChild(child) { this.children.push(child); }
  addEventListener(event, callback) { this.events[event] = callback; }
  click() { this.clicked = true; this.events.click?.(); }
}

function load(snapshot) {
  const elements = new Map();
  const element = id => {
    if (!elements.has(id)) elements.set(id, new Element());
    return elements.get(id);
  };
  element('snapshotData').textContent = Buffer.from(JSON.stringify({
    source: '/tmp/Example/segments.csv', generatedAt: '2026-11-07T10:00:00Z', ...snapshot,
  })).toString('base64');
  let printed = false;
  const document = {
    getElementById: element,
    querySelector: element,
    createElement: () => new Element(),
  };
  class FileReader {
    readAsText(file) {
      if (file.error) this.onerror();
      else { this.result = file.text; this.onload(); }
    }
  }
  vm.runInNewContext(script, { document, window: { print() { printed = true; } }, FileReader, atob, TextDecoder, Uint8Array });
  return { element, printed: () => printed };
}

test('snapshot opens immediately with project totals and separate tasks across projects', () => {
  const page = load({ csv: header + record('Orca: Review', '01:00:00') + record('Orca: Meeting', '00:30:00') + record('Client B: Review', '00:15:00') + record('Admin', '00:05:00') });
  assert.equal(page.element('report').hidden, false);
  assert.equal(page.element('dropzone').hidden, true);
  assert.equal(page.element('heroTotal').textContent, '1h 50m');
  assert.equal(page.element('statTasks').textContent, '4');
  assert.deepEqual(page.element('projectBars').children.map(row => row.title), ['Orca — 01:30:00', 'Client B — 00:15:00', 'No project — 00:05:00']);
  assert.equal(page.element('taskBars').children.length, 4);
  assert.match(page.element('#segmentsTable tbody').children[0].innerHTML, /<td>Orca<\/td><td>Review<\/td>/);
  assert.match(page.element('sourceInfo').textContent, /Example\/segments.csv/);
  assert.match(page.element('sourceInfo').textContent, /Saved segments only/);
});

test('project parsing uses only the first colon, trims parts, and requires both parts', () => {
  const page = load({ csv: header + record(' Client A : Review: follow-up ', '00:10:00') + record('Meeting:', '00:05:00') + record(': Admin', '00:03:00') + record(' : ', '00:02:00') });
  assert.deepEqual(page.element('projectBars').children.map(row => row.title).sort(), ['Client A — 00:10:00', 'No project — 00:10:00']);
  assert.match(page.element('#segmentsTable tbody').children[0].innerHTML, /<td>Client A<\/td><td>Review: follow-up<\/td>/);
});

test('Unicode, quoted commas, quotes, multiline names and HTML remain intact and escaped', () => {
  const task = 'Café: "报价", first\r\nsecond\rthird </script><img src=x onerror=alert(1)>';
  const page = load({ csv: header + record(task, '00:01:00') });
  assert.equal(page.element('statSegments').textContent, '1');
  assert.equal(page.element('taskBars').children[0].title, task + ' — 00:01:00');
  const html = page.element('#segmentsTable tbody').children[0].innerHTML;
  assert.ok(html.includes('报价'));
  assert.ok(html.includes('&lt;/script&gt;&lt;img'));
  assert.ok(!html.includes('<img'));
});

test('missing, empty and header-only files show a useful empty state', () => {
  for (const snapshot of [{ message: 'No saved segments yet.' }, { csv: '' }, { csv: header }]) {
    const page = load(snapshot);
    assert.equal(page.element('report').hidden, true);
    assert.equal(page.element('dropzone').hidden, false);
    assert.equal(page.element('loadStatus').hidden, false);
    assert.match(page.element('loadStatus').textContent, /No saved segments/);
  }
});

test('read errors are visible and invalid CSV does not render misleading totals', () => {
  const failed = load({ message: 'Could not read segments.csv: permission denied.' });
  assert.match(failed.element('loadStatus').textContent, /permission denied/);
  for (const csv of ['Wrong,Header\nA,B', header + '"Unfinished']) {
    const page = load({ csv });
    assert.equal(page.element('loadError').hidden, false);
    assert.equal(page.element('report').hidden, true);
  }
});

test('file picker, replacement file, drag and drop, and print remain usable', () => {
  const page = load({ csv: header + record('Old: Task', '00:01:00') });
  page.element('loadBtn').click();
  page.element('pickBtn').click();
  assert.equal(page.element('fileInput').clicked, true);
  page.element('fileInput').files = [{ name: 'another.csv', text: header + record('New: Task', '00:02:00') }];
  page.element('fileInput').events.change();
  assert.equal(page.element('projectBars').children[0].title, 'New — 00:02:00');
  assert.match(page.element('sourceInfo').textContent, /another.csv/);
  assert.ok(!page.element('sourceInfo').textContent.includes('/tmp/Example'));
  page.element('loadBtn').click();
  page.element('dropzone').events.drop({ preventDefault() {}, dataTransfer: { files: [{ name: 'dropped.csv', text: header + record('Dropped', '00:03:00') }] } });
  assert.equal(page.element('taskBars').children[0].title, 'Dropped — 00:03:00');
  page.element('printBtn').click();
  assert.equal(page.printed(), true);
});

const multiPeriodCSV = header +
  record('Orca: Older', '00:20:00', '2025-12-31') +
  record('Orca: Latest', '01:00:00', '2026-11-07') +
  record('Kson: Earlier month', '00:30:00', '2026-02-01') +
  record('Orca: Latest meeting', '00:15:00', '2026-11-02');

function select(page, id, value) {
  page.element(id).value = value;
  page.element(id).events.change();
}

test('defaults to latest recorded month and lists only available months newest first', () => {
  const page = load({ csv: multiPeriodCSV });
  assert.equal(page.element('periodMode').value, 'month');
  assert.equal(page.element('periodValue').value, '2026-11');
  assert.deepEqual(page.element('periodValue').children.map(option => [option.value, option.textContent]), [
    ['2026-11', 'November 2026'], ['2026-02', 'February 2026'], ['2025-12', 'December 2025'],
  ]);
  assert.equal(page.element('heroTotal').textContent, '1h 15m');
  assert.equal(page.element('statSegments').textContent, '2');
  assert.equal(page.element('statTasks').textContent, '2');
  assert.equal(page.element('statRange').textContent, '2026-11-02 → 2026-11-07');
  assert.equal(page.element('#segmentsTable tbody').children.length, 2);
  assert.equal(page.element('periodHeading').textContent, 'November 2026');
});

test('changing month filters every chart, summary and segment table', () => {
  const page = load({ csv: multiPeriodCSV });
  select(page, 'periodValue', '2026-02');
  assert.equal(page.element('heroTotal').textContent, '30m');
  assert.equal(page.element('statSegments').textContent, '1');
  assert.equal(page.element('statTasks').textContent, '1');
  assert.equal(page.element('statRange').textContent, '2026-02-01');
  assert.deepEqual(page.element('projectBars').children.map(row => row.title), ['Kson — 00:30:00']);
  assert.deepEqual(page.element('taskBars').children.map(row => row.title), ['Kson: Earlier month — 00:30:00']);
  assert.deepEqual(page.element('dayBars').children.map(row => row.title), ['2026-02-01 — 00:30:00']);
  assert.equal(page.element('#segmentsTable tbody').children.length, 1);
  assert.match(page.element('#segmentsTable tbody').children[0].innerHTML, /Earlier month/);
  assert.equal(page.element('periodHeading').textContent, 'February 2026');
});

test('yearly view totals the selected year and keeps the year when switching modes', () => {
  const page = load({ csv: multiPeriodCSV });
  select(page, 'periodMode', 'year');
  assert.deepEqual(page.element('periodValue').children.map(option => option.value), ['2026', '2025']);
  assert.equal(page.element('periodValue').value, '2026');
  assert.equal(page.element('periodLabel').textContent, 'Year');
  assert.equal(page.element('heroTotal').textContent, '1h 45m');
  assert.equal(page.element('statSegments').textContent, '3');
  assert.equal(page.element('#segmentsTable tbody').children.length, 3);
  select(page, 'periodValue', '2025');
  assert.equal(page.element('heroTotal').textContent, '20m');
  assert.equal(page.element('periodHeading').textContent, '2025');
  select(page, 'periodMode', 'month');
  assert.equal(page.element('periodValue').value, '2025-12');
  assert.equal(page.element('periodHeading').textContent, 'December 2025');
  select(page, 'periodMode', 'year');
  assert.equal(page.element('periodValue').value, '2025');
});

test('all time restores all data and printed reports retain the selected period', () => {
  const page = load({ csv: multiPeriodCSV });
  select(page, 'periodMode', 'all');
  assert.equal(page.element('periodChoice').hidden, true);
  assert.equal(page.element('heroTotal').textContent, '2h 5m');
  assert.equal(page.element('statSegments').textContent, '4');
  assert.equal(page.element('periodHeading').textContent, 'All time');
  select(page, 'periodMode', 'year');
  assert.equal(page.element('periodChoice').hidden, false);
  select(page, 'periodValue', '2025');
  page.element('printBtn').click();
  assert.equal(page.printed(), true);
  assert.equal(page.element('periodHeading').textContent, '2025');
  assert.match(page.element('reportMeta').textContent, /^2025 · /);
  assert.equal(page.element('#segmentsTable tbody').children.length, 1);
});

test('loading another file replaces period choices and defaults to its latest month', () => {
  const page = load({ csv: multiPeriodCSV });
  select(page, 'periodMode', 'year');
  page.element('fileInput').files = [{ name: 'replacement.csv', text: header + record('New', '00:10:00', '2023-04-10') }];
  page.element('fileInput').events.change();
  assert.equal(page.element('periodMode').value, 'month');
  assert.equal(page.element('periodValue').value, '2023-04');
  assert.deepEqual(page.element('periodValue').children.map(option => option.value), ['2023-04']);
  assert.equal(page.element('heroTotal').textContent, '10m');
});

test('periods use the recorded start date across midnight and support leap days', () => {
  const csv = header + 'Orca: Midnight,2025-12-31 23:30:00,2026-01-01 00:30:00,01:00:00\n' + record('Leap day', '00:10:00', '2024-02-29');
  const page = load({ csv });
  assert.equal(page.element('periodValue').value, '2025-12');
  assert.equal(page.element('heroTotal').textContent, '1h 0m');
  assert.deepEqual(page.element('periodValue').children.map(option => option.value), ['2025-12', '2024-02']);
  for (const day of ['2025-02-29', '2026-13-01', '2026-04-31', 'bad-date']) {
    const invalid = load({ csv: header + record('Invalid', '00:10:00', day) });
    assert.equal(invalid.element('report').hidden, true);
    assert.match(invalid.element('loadError').textContent, /Invalid Start date/);
  }
});
