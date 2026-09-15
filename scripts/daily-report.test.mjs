// The two clock rules in the emailer: which day a report covers, and whether
// the attempt that is running should send at all.
//
// Worth checking because getting either wrong is silent. Get the day wrong and
// you still get an email, it just describes the wrong day -- which is what
// happened on the first scheduled run, due 7pm Monday and fired 1:38am
// Tuesday. Get the send rule wrong and no email arrives at all, or six do.
//
// No packages and no runner. Just:  node scripts/daily-report.test.mjs

import { serviceDate, tooEarly } from './daily-report.mjs';

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

// The six attempts the workflow makes, at 07:52, 08:22, 08:52, 09:22, 09:52
// and 10:22 UTC. Melbourne is UTC+10 in winter, so the first two land before
// the vans are in and must hold off; UTC+11 in summer, so the first one is
// already past 6:50pm and goes. Either way a delayed attempt sends rather
// than waiting, because late beats never.
const sendCases = [
  ['winter 1st attempt, 5:52pm',      '2026-09-14T07:52:00Z', true],
  ['winter 2nd attempt, 6:22pm',      '2026-09-14T08:22:00Z', true],
  ['winter 3rd attempt, 6:52pm',      '2026-09-14T08:52:00Z', false],
  ['winter 4th attempt, 7:22pm',      '2026-09-14T09:22:00Z', false],
  ['summer 1st attempt, 6:52pm',      '2026-10-05T07:52:00Z', false],
  ['summer 6th attempt, 9:22pm',      '2026-10-05T10:22:00Z', false],
  ['the real 1:38am failure sends',   '2026-09-14T15:38:18Z', false],
  ['9am the morning after sends',     '2026-09-14T23:00:00Z', false],
  ['11:59pm sends',                   '2026-09-14T13:59:00Z', false],
  ['midday exactly waits for 6:50pm', '2026-09-15T02:00:00Z', true],
  ['2pm waits for 6:50pm',            '2026-09-15T04:00:00Z', true],
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
console.log('');
for (const [name, iso, want] of sendCases) {
  const got = tooEarly(new Date(iso));
  const melbourne = new Date(iso).toLocaleString('en-AU',
    { timeZone: 'Australia/Melbourne', dateStyle: 'short', timeStyle: 'short' });
  const label = got ? 'holds off' : 'sends';
  if (got === want) {
    console.log(`  ok    ${name.padEnd(32)} ${melbourne.padEnd(20)} -> ${label}`);
  } else {
    failed++;
    console.log(`  FAIL  ${name.padEnd(32)} ${melbourne.padEnd(20)} -> ${label}, wanted ${
      want ? 'holds off' : 'sends'}`);
  }
}

const total = cases.length + sendCases.length;
console.log(failed ? `\n${failed} failed` : `\n${total} checks passed`);
process.exit(failed ? 1 : 0);
