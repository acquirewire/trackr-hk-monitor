# Trackr opening monitor

Watches the [Trackr — Hong Kong Finance, Summer Internships](https://app.the-trackr.com/hong-kong-finance/summer-internships)
page and sends an [ntfy](https://ntfy.sh) push **only when a bank's application opens up**.

It polls the same API the website uses and computes each programme's status with
the *exact* rule the site uses:

| status    | meaning                                                        |
|-----------|----------------------------------------------------------------|
| not-open  | no opening date yet, or the opening date is in the future      |
| open      | opening date has passed and it hasn't closed                   |
| closed    | the closing date's end-of-day has passed                       |

An alert fires for a programme **only** when its status changes to `open`
(a bank opening its application, or a brand-new already-open row appearing).
Every other change — added notes, closing-date edits, new not-open rows,
rows going closed, renames — is tracked silently and never notified.

Each notification's title is the bank name; tapping it opens that bank's real
application page.

## How it runs

A GitHub Actions workflow (`.github/workflows/monitor.yml`) runs every 15 minutes
on GitHub's servers — so it keeps working even when your laptop is off. It commits
the updated `state.json` (the memory of what was open last time) back to the repo
after each check.

The ntfy topic is stored as the encrypted repo secret `NTFY_TOPIC` (never committed).

## Run it locally

```powershell
# dry run — prints what it would send, sends nothing
./trackr-monitor.ps1 -DryRun

# real run (reads ntfyTopic from config.json, or env NTFY_TOPIC)
./trackr-monitor.ps1

# forget history and re-seed the baseline
./trackr-monitor.ps1 -Reset
```

## Files

- `trackr-monitor.ps1` — the monitor (PowerShell; runs on Windows and on the Linux runner via `pwsh`)
- `config.json` — API query params + ntfy server/topic defaults
- `state.json` — last-seen status per programme (auto-managed)
- `.github/workflows/monitor.yml` — the 15-minute schedule
