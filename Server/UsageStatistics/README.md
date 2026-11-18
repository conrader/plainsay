# Plainsay usage statistics collector

The public API and its reverse-proxy configuration are maintained outside this repository.
`Sources/MiniTranscribeServer` is a private upstream that handles Cloud audio.
Run this Python 3.10+ collector separately with the standard library and SQLite.

## Prepare the API host

1. Run `python3 server.py --db /var/lib/plainsay-usage/totals.sqlite3` as a dedicated
   service user on the API host. Give it an owner-only data directory and use
   the service manager to restart it after failures. The collector binds to
   `127.0.0.1:8765`. Keep the SQLite database off public paths and out of
   snapshots and backups so the 90-calendar-day expiry applies.
2. Proxy only `POST https://api.plainsay.app/v1/usage-statistics` to that loopback
   route. Require TLS, limit bodies to 16 KiB, enforce header/body timeouts and
   a global route request/connection limit, and turn off upstream retries.
   Do not forward client addresses, cookies, or credentials. Disable access and
   error request logging, header/body capture, tracing, and IP retention for
   this path at every layer (including any CDN, WAF, load balancer and proxy).
   Avoid IP-based limits or challenges that retain client state.
3. On staging, verify a valid test batch returns HTTP 204 and increments its
   expected totals. Check malformed and rejected requests, including proxy
   rejections, for leaks in all logging and observability sinks. Use separate
   staging totals. Run the macOS build and tests before releasing the client,
   and publish the privacy notice with the release.

## Read the totals

```sh
python3 report.py --db /var/lib/plainsay-usage/totals.sqlite3 --days 30
```

Run the report with read access to the database. Keep totals and reports
private. Cells for versions, usage buckets, modes, language hints and failures
with fewer than five contributing install-days are omitted from the CSV.

- `daily_active` counts reported install-days. An active day has at least one
  standard recording reaching transcription or a counted failure during a
  standard dictation attempt. Launches, private dictations, correction commands,
  cancelled and too-short recordings, and recovered audio are excluded.
- `weekly_active` counts the one contribution each installation makes in
  each Monday–Sunday UTC week. The client claims it against its first
  dispatched active day for that week, even when uploading several offline days.
  Do not sum daily totals for weekly unique counts. The most recent days and
  week can change as late batches arrive.
- `dictations`, `audio_minutes` and `mode_*` count install-days within each
  bucket. Dictation/audio totals include captured recordings that fail
  transcription. `mode_polishing` counts Polishing attempts and can overlap
  speech modes. Version bins count install-days by the version at the first
  counted event of each day. `language_hint` counts install-days for each
  configured primary speech hint used that day. `auto` covers automatic or
  unavailable hints. `failure` sums capped errors by stage, including
  clipboard fallbacks when insertion cannot be attempted.

See the [example body and consent rationale](../../README.md#optional-anonymous-usage-statistics).
The collector accepts up to seven closed UTC days, validates the complete
schema, and merges independent totals in one transaction. It keeps no request
rows or replay keys. Totals expire based on their UTC day or week start. The
client checks connectivity before sending and makes one attempt per UTC day.
It reserves the batch on disk before sending and skips retries after dispatch
because a lost response could follow a successful merge.

Counts cover opted-in clients. Reinstalling or withdrawing and giving consent
again in the same week can increase the weekly count. Long periods offline,
ambiguous network failures and server downtime can reduce counts. The
collector accepts anonymous submissions, so fabricated or replayed batches
can bias the totals. The global limit bounds load without tracking people.

Run the collector tests with `python3 -B -m unittest discover -s Server/UsageStatistics -v`
from the repository root.
