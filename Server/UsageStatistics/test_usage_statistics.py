import io
import json
import re
import sqlite3
import unittest
from contextlib import closing, redirect_stderr
from copy import deepcopy
from datetime import date
from pathlib import Path
from types import SimpleNamespace

from report import report_rows
from server import LANGUAGES, RateLimiter, UsageHandler, aggregate, decode_batch, open_store, prune

ROOT = Path(__file__).resolve().parents[2]
TODAY = date(2026, 11, 18)


def example():
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    privacy_section = readme.split("### Optional anonymous usage statistics", 1)[1]
    return json.loads(re.search(r"```json\n(.*?)\n```", privacy_section, re.DOTALL)[1])


def decode(value):
    return decode_batch(json.dumps(value).encode(), TODAY)


class UsageStatisticsTests(unittest.TestCase):
    def test_documented_payload_matches_schema(self):
        self.assertEqual(decode(example()), example()["days"])

    def test_client_and_collector_language_allowlists_match(self):
        source = (ROOT / "Sources/PlainsayCore/SupportedLanguage.swift").read_text()
        self.assertEqual(LANGUAGES, set(re.findall(r'SupportedLanguage\(code: "(\w+)"', source)) | {"auto"})

    def test_rejects_unknown_fields_and_arbitrary_values(self):
        for field, value in [
            ("text", "secret"), ("ip", "192.0.2.10"), ("bundle_id", "editor"),
            ("app_version", "/tmp/test"), ("macos_version", "15.7.1"),
            ("languages", ["pl-PL"]), ("languages", ["pl", "pl"]),
            ("modes", {"unknown": "1-4"}), ("modes", {"local": "0"}),
            ("failures", {"error message": 1}), ("failures", {"model": 101}),
            ("failures", {"model": True}), ("weekly_active", 1),
            ("dictations", 8), ("audio_minutes", "1.25"),
        ]:
            with self.subTest(field=field, value=value):
                value_to_decode = example()
                value_to_decode["days"][0][field] = value
                with self.assertRaises(ValueError):
                    decode(value_to_decode)

    def test_rejects_duplicate_keys_days_and_weekly_claims(self):
        with self.assertRaises(ValueError):
            decode_batch(b'{"schema":1,"schema":1,"days":[]}', TODAY)
        batch = example()
        repeated = deepcopy(batch["days"][0])
        batch["days"].append(repeated)
        with self.assertRaises(ValueError):
            decode(batch)
        repeated["day"] = "2026-11-17"
        with self.assertRaises(ValueError):
            decode(batch)
        repeated["weekly_active"] = False
        self.assertEqual(len(decode(batch)), 2)

    def test_accepts_only_recent_closed_days(self):
        batch = example()
        for day in ("2026-11-19", "2026-11-09", "20261116", "2026-11-31"):
            with self.subTest(day=day), self.assertRaises(ValueError):
                batch["days"][0]["day"] = day
                decode(batch)
        # One day of clock skew either way must not drop a whole batch.
        for day in ("2026-11-18", "2026-11-11", "2026-11-10"):
            with self.subTest(day=day):
                batch["days"][0]["day"] = day
                self.assertEqual(len(decode(batch)), 1)

    def test_global_rate_limiter_refills_without_client_state(self):
        now = [0.0]
        limiter = RateLimiter(2, clock=lambda: now[0])
        self.assertTrue(limiter.allow())
        self.assertTrue(limiter.allow())
        self.assertFalse(limiter.allow())
        now[0] += 30
        self.assertTrue(limiter.allow())
        self.assertFalse(limiter.allow())

    def test_counts_weekly_on_monday_and_rolls_up_independent_marginals(self):
        batch = example()
        batch["days"][0]["day"] = "2026-11-17"
        batch["days"].append(dict(batch["days"][0], day="2026-11-16", weekly_active=False))
        with closing(open_store(":memory:")) as db, db:
            aggregate(db, decode(batch))
            rows = db.execute("SELECT day, metric, label, value, contributors FROM totals").fetchall()
            self.assertIn(("2026-11-16", "weekly_active", "", 1, 1), rows)
            self.assertNotIn(("2026-11-17", "weekly_active", "", 1, 1), rows)
            self.assertIn(("2026-11-17", "daily_active", "", 1, 1), rows)
            self.assertIn(("2026-11-17", "language_hint", "pl", 1, 1), rows)
            self.assertIn(("2026-11-17", "mode_polishing", "1-4", 1, 1), rows)
            tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
            self.assertEqual(tables, [("totals",)])

    def test_report_suppresses_small_cells_and_expired_totals_are_deleted(self):
        days = decode(example())
        with closing(open_store(":memory:")) as db, db:
            for _ in range(5):
                aggregate(db, days)
            aggregate(db, [dict(days[0], day="2026-11-17", failures={"model": 6}, weekly_active=False)])
            db.execute("INSERT INTO totals VALUES ('2026-01-01', 'daily_active', '', 1, 1)")
            prune(db, TODAY)
            rows = list(report_rows(db, TODAY, 30))
            self.assertIn(("2026-11-16", "failure", "polishing", 5, 5), rows)
            self.assertIn(("2026-11-17", "daily_active", "", 1, 1), rows)
            self.assertFalse(any(row[2] == "model" for row in rows))
            self.assertEqual(db.execute("SELECT COUNT(*) FROM totals WHERE day = '2026-01-01'").fetchone(), (0,))

    def test_http_validation_has_no_request_logging_or_partial_write(self):
        body = json.dumps(example()).encode()
        invalid = example()
        invalid["days"].append(dict(invalid["days"][0], day="2026-11-17", text="secret"))
        with closing(open_store(":memory:")) as db, redirect_stderr(io.StringIO()) as stderr:
            allowed = [True]

            def post(path, body, *, content_type="application/json", length=None):
                request = (
                    f"POST {path} HTTP/1.1\r\nContent-Type: {content_type}\r\n"
                    f"Content-Length: {len(body) if length is None else length}\r\n\r\n"
                ).encode() + body
                connection = FakeConnection(request)
                UsageHandler(connection, ("192.0.2.10", 5555), SimpleNamespace(
                    db=db, today=lambda: TODAY, limiter=SimpleNamespace(allow=lambda: allowed[0])
                ))
                return bytes(connection.response)

            self.assertIn(b" 404 ", post("/v1/usage-statistics?secret", body))
            self.assertIn(b" 415 ", post("/v1/usage-statistics", body, content_type="text/plain"))
            self.assertIn(b" 413 ", post("/v1/usage-statistics", b"x" * 16385))
            self.assertIn(b" 400 ", post("/v1/usage-statistics", json.dumps(invalid).encode()))
            self.assertIn(b" 400 ", post("/v1/usage-statistics", body[:-1], length=len(body)))
            allowed[0] = False
            self.assertIn(b" 429 ", post("/v1/usage-statistics", body))
            allowed[0] = True
            self.assertEqual(db.execute("SELECT COUNT(*) FROM totals").fetchone(), (0,))
            reply = post("/v1/usage-statistics", body)
            self.assertIn(b" 204 ", reply)
            self.assertNotIn(b"secret", reply)
            self.assertEqual(stderr.getvalue(), "")
            self.assertEqual(db.execute("SELECT value FROM totals WHERE metric='daily_active'").fetchone(), (1,))


class FakeConnection:
    def __init__(self, request):
        self.request = io.BytesIO(request)
        self.response = bytearray()

    def settimeout(self, _seconds):
        pass

    def makefile(self, _mode, _buffer_size):
        return self.request

    def sendall(self, data):
        self.response.extend(data)


if __name__ == "__main__":
    unittest.main()
