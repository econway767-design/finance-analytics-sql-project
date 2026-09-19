"""
Runs every query in example_queries.sql against finance_real.db and
prints each result set, labeled by its numbered comment header.

Usage:
    python run_example_queries.py
"""
import sqlite3
import re

DB_PATH = "finance_real.db"
SQL_PATH = "example_queries.sql"

conn = sqlite3.connect(DB_PATH)
sql = open(SQL_PATH).read()

# split into chunks on each numbered "-- N." comment header
chunks = re.split(r"\n(?=-- \d+\.)", sql)
chunks = [c.strip() for c in chunks if c.strip() and not c.strip().startswith("-- ====")]

for chunk in chunks:
    header = chunk.splitlines()[0].lstrip("- ").strip()
    print("\n" + "=" * 70)
    print(header)
    print("=" * 70)
    try:
        cur = conn.execute(chunk)
        cols = [d[0] for d in cur.description]
        rows = cur.fetchall()
        print(" | ".join(cols))
        for row in rows[:15]:            # cap output so one query doesn't flood the screen
            print(" | ".join(str(v) for v in row))
        if len(rows) > 15:
            print(f"... ({len(rows) - 15} more rows)")
        if not rows:
            print("(no rows returned)")
    except Exception as e:
        print(f"ERROR: {e}")

conn.close()
