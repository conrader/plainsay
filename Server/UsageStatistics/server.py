"""Loopback-only, first-party usage statistics collector."""
import argparse
import json
import os
import re
import sqlite3
from contextlib import closing
from datetime import date, datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROUTE = "/v1/usage-statistics"
MAX_BODY = 16 * 1024
PENDING_DAYS = 7
RETENTION_DAYS = 90
DAY_KEYS = {
    "day", "weekly_active", "app_version", "macos_version", "dictations",
    "audio_minutes", "modes", "languages", "failures",
}
DICTATION_BUCKETS = ("0", "1-4", "5-19", "20-49", "50-99", "100+")
AUDIO_BUCKETS = ("0", "<1", "1-<5", "5-<15", "15-<60", "60+")
MODES = {"local", "cloud", "remote", "polishing"}
FAILURES = {"model", "permission", "recording", "transcription", "polishing", "insertion"}
# SupportedLanguage.all plus the automatic/unknown source-language hint.
LANGUAGES = set("""
en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro
da hu ta no th ur hr bg lt la mi ml cy sk te fa lv bn sr az sl kn et mk br
eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af oc ka be tg sd gu am
yi lo uz fo ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su yue auto
""".split())


def utc_today():
    return datetime.now(timezone.utc).date()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def require(condition):
    if not condition:
        raise ValueError("invalid report")


def decode_batch(body, today):
    batch = json.loads(body.decode("utf-8"), object_pairs_hook=unique_object)
    require(type(batch) is dict and batch.keys() == {"schema", "days"})
    require(type(batch["schema"]) is int and batch["schema"] == 1)
    days = batch["days"]
    require(type(days) is list and 1 <= len(days) <= PENDING_DAYS)
    seen_days, claimed_weeks = set(), set()
    for row in days:
        require(type(row) is dict and row.keys() == DAY_KEYS)
        raw_day = row["day"]
        require(type(raw_day) is str and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", raw_day))
        day = date.fromisoformat(raw_day)
        require(1 <= (today - day).days <= PENDING_DAYS and day not in seen_days)
        seen_days.add(day)
        require(type(row["weekly_active"]) is bool)
        week = day - timedelta(days=day.weekday())
        if row["weekly_active"]:
            require(week not in claimed_weeks)
            claimed_weeks.add(week)
        for key, pattern in (("app_version", r"[0-9]{1,3}(\.[0-9]{1,3}){1,2}"),
                             ("macos_version", r"[0-9]{1,3}\.[0-9]{1,3}")):
            version = row[key]
            require(type(version) is str and (version == "unknown" or re.fullmatch(pattern, version)))
        require(row["dictations"] in DICTATION_BUCKETS and row["audio_minutes"] in AUDIO_BUCKETS)
        modes = row["modes"]
        require(type(modes) is dict and modes.keys() <= MODES)
        require(all(bucket in DICTATION_BUCKETS[1:] for bucket in modes.values()))
        languages = row["languages"]
        require(type(languages) is list and len(languages) <= len(LANGUAGES))
        require(all(type(code) is str and code in LANGUAGES for code in languages))
        require(len(set(languages)) == len(languages))
        failures = row["failures"]
        require(type(failures) is dict and failures.keys() <= FAILURES)
        require(all(type(count) is int and 1 <= count <= 100 for count in failures.values()))
        if row["dictations"] == "0":
            require(row["audio_minutes"] == "0" and not modes and not languages and failures)
        else:
            require(row["audio_minutes"] != "0" and languages)
    return days


def open_store(path):
    db = sqlite3.connect(path)
    try:
        db.execute("PRAGMA secure_delete = ON")
        db.execute("""
            CREATE TABLE IF NOT EXISTS totals (
                day TEXT NOT NULL,
                metric TEXT NOT NULL,
                label TEXT NOT NULL,
                value INTEGER NOT NULL,
                contributors INTEGER NOT NULL,
                PRIMARY KEY (day, metric, label)
            ) WITHOUT ROWID
        """)
    except Exception:
        db.close()
        raise
    return db


def prune(db, today):
    cutoff = today - timedelta(days=RETENTION_DAYS - 1)
    db.execute("DELETE FROM totals WHERE day < ?", (cutoff.isoformat(),))


def aggregate(db, days):
    def add(day, metric, label="", value=1):
        db.execute("""
            INSERT INTO totals (day, metric, label, value, contributors)
            VALUES (?, ?, ?, ?, 1)
            ON CONFLICT (day, metric, label) DO UPDATE SET
                value = totals.value + excluded.value,
                contributors = totals.contributors + 1
        """, (day, metric, label, value))

    for row in days:
        day = row["day"]
        add(day, "daily_active")
        if row["weekly_active"]:
            week = date.fromisoformat(day)
            add((week - timedelta(days=week.weekday())).isoformat(), "weekly_active")
        for key in ("app_version", "macos_version", "dictations", "audio_minutes"):
            add(day, key, row[key])
        for mode, bucket in row["modes"].items():
            add(day, "mode_" + mode, bucket)
        for code in row["languages"]:
            add(day, "language_hint", code)
        for failure, count in row["failures"].items():
            add(day, "failure", failure, count)


class UsageHandler(BaseHTTPRequestHandler):
    def setup(self):
        self.request.settimeout(5)
        super().setup()

    def log_message(self, *_args):
        pass

    def send_error(self, code, message=None, explain=None):
        # BaseHTTPRequestHandler can echo the request line in its error body.
        self.reply(code)

    def reply(self, code):
        self.send_response_only(code)
        if code != 204:
            self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def do_POST(self):
        if self.path != ROUTE:
            self.reply(404)
            return
        if (self.headers.get_content_type() != "application/json"
                or self.headers.get("Transfer-Encoding") is not None
                or self.headers.get("Content-Encoding") is not None):
            self.reply(415)
            return
        lengths = self.headers.get_all("Content-Length", [])
        if len(lengths) != 1 or not re.fullmatch(r"[0-9]{1,5}", lengths[0]):
            self.reply(400)
            return
        length = int(lengths[0])
        if not 1 <= length <= MAX_BODY:
            self.reply(413)
            return

        today = self.server.today()
        try:
            body = self.rfile.read(length)
            require(len(body) == length)
            days = decode_batch(body, today)
        except (ValueError, RecursionError, TimeoutError):
            self.reply(400)
            return
        try:
            with self.server.db:
                aggregate(self.server.db, days)
        except sqlite3.Error:
            self.reply(503)
            return
        self.reply(204)


class UsageServer(HTTPServer):
    def __init__(self, port, db, today=utc_today):
        # Raise a configuration/DB error at startup without accepting requests.
        self.db = db
        self.today = today
        self.last_prune = None
        self.prune_if_needed()
        super().__init__(("127.0.0.1", port), UsageHandler)

    def prune_if_needed(self):
        today = self.today()
        if today != self.last_prune:
            with self.db:
                prune(self.db, today)
            self.last_prune = today

    def service_actions(self):
        self.prune_if_needed()

    def handle_error(self, _request, _client_address):
        # The default handler logs the peer address and traceback.
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True, type=Path)
    parser.add_argument("--port", default=8765, type=int)
    args = parser.parse_args()
    os.umask(0o077)
    with closing(open_store(args.db)) as db, UsageServer(args.port, db) as server:
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
