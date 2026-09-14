// Which day does the report cover?
//
// The one thing in the emailer worth checking, because getting it wrong is
// silent: you get an email, it just describes the wrong day. That is exactly
// what happened on the first scheduled run -- due 7pm Monday, fired 1:38am
// Tuesday, reported an empty Tuesday.
//
// No packages and no runner. Just:  node scripts/daily-report.test.mjs

import { serviceDate } from './daily-report.mjs';

// Melbourne is UTC+10 (AEST) in winter and UTC+11 (AEDT) from the first
// Sunday in October, which in 2026 is the 4th.
const cases = [
  ['on time, 7pm Mon',            '2026-09-14T09:17:00Z', '2026-09-14'],
  ['the real failure, 1:38am Tue','2026-09-14T15:38:18Z', '2026-09-14'],
  ['very late, 9am Tue',          '2026-09-14T23:00:00Z', '2026-09-14'],
  ['11:59pm Mon',                 '2026-09-14T13:59:00Z', '2026-09-14'],
  ['12:01am Tue',                 '2026-09-14T14:01:00Z', '2026-09-14'],
  ['Saturday evening',            '2026-09-19T09:17:00Z', '2026-09-19'],
  ['Saturday run, fires Sunday',  '2026-09-19T15:30:00Z', '2026-09-19'],
  ['summer, 8:17pm Mon',          '2026-10-05T09:17:00Z', '2026-10-05'],
  ['summer, 1:30am Tue',          '2026-10-05T14:30:00Z', '2026-10-05'],
  ['the night the clocks change', '2026-10-03T15:00:00Z', '2026-10-03'],
  // Past midday the delay is so long that the current day is the better answer.
  ['12:30pm, gives up on yesterday', '2026-09-15T02:30:00Z', '2026-09-15'],
];

let failed = 0;
for (const [name, iso, want] of cases) {
  const got = serviceDate(new Date(iso));
  const melbourne = new Date(iso).toLocaleString('en-AU',
    { timeZone: 'Australia/Melbourne', dateStyle: 'short', timeStyle: 'short' });
  if (got === want) {
    console.log(`  ok    ${name.padEnd(32)} ${melbourne.padEnd(20)} -> ${got}`);
  } else {
    failed++;
    console.log(`  FAIL  ${name.padEnd(32)} ${melbourne.padEnd(20)} -> ${got}, wanted ${want}`);
  }
}
console.log(failed ? `\n${failed} failed` : `\n${cases.length} checks passed`);
process.exit(failed ? 1 : 0);
