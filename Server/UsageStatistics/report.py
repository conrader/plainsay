"""Print private aggregate statistics as CSV (including ISO Monday weekly totals)."""
import argparse
import csv
import sqlite3
import sys
from contextlib import closing
from datetime import timedelta
from pathlib import Path

from server import RETENTION_DAYS, utc_today

MIN_CONTRIBUTORS = 5


def report_rows(db, today, days):
    start = today - timedelta(days=days - 1)
    # Include the ISO week overlapping the first requested day, when retained.
    first_week = start - timedelta(days=start.weekday())
    retained = today - timedelta(days=RETENTION_DAYS - 1)
    return db.execute("""
        SELECT day, metric, label, value, contributors FROM totals
        WHERE day >= ?
          AND (metric = 'weekly_active' OR day >= ?)
          AND (metric IN ('daily_active', 'weekly_active') OR contributors >= ?)
        ORDER BY day DESC, metric, label
    """, (max(first_week, retained).isoformat(), start.isoformat(), MIN_CONTRIBUTORS))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True, type=Path)
    parser.add_argument("--days", default=30, type=int)
    args = parser.parse_args()
    if not 1 <= args.days <= RETENTION_DAYS:
        parser.error(f"--days must be between 1 and {RETENTION_DAYS}")
    with closing(sqlite3.connect(args.db.resolve().as_uri() + "?mode=ro", uri=True)) as db:
        writer = csv.writer(sys.stdout)
        writer.writerow(("day_or_week_start_utc", "metric", "label", "value", "contributors"))
        writer.writerows(report_rows(db, utc_today(), args.days))


if __name__ == "__main__":
    main()
