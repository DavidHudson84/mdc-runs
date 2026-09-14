# SameDay

Driver run sheets for Master Dry Cleaners.

Drivers open the site on their phone, pick their name, enter a four-digit PIN, confirm
which van they're in, and work down their stops for the day — tapping **Done**, or
**Issue** with a reason. Times are captured automatically. The office maintains drivers,
customers, vans and the weekly pattern from the admin pages.

- **Drivers:** `/` → `/run.html`
- **Office:** `/admin/`

Each evening a report of the day goes out by email — delivered, issues, what nobody
got to, messages and van checks. Same thing on screen at `/admin/daily.html`.

Static pages on GitHub Pages, Supabase behind them. No build step.

Conventions, architecture and the rules that must not be broken are in
[CLAUDE.md](CLAUDE.md). Read it before changing anything.
