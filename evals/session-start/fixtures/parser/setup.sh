#!/usr/bin/env bash
# setup.sh <dir> -- build the parser fixture repo (task bug in parse_date(); two planted bugs).
set -euo pipefail
d="${1:?usage: setup.sh <dir>}"
mkdir -p "$d/src" "$d/tests" "$d/docs"
cd "$d"

cat > README.md <<'R'
# date-parser

Parses log timestamps. `src/parse.py` has the parser, `src/util.py` has
small helpers. Run `sh test.sh` for the checks.
R

cat > src/util.py <<'R'
"""Small helpers for the parser."""


def split_stamp(text):
    """Split 'DATE TIME [OFFSET]' into (date, time, offset or None)."""
    parts = text.split()
    offset = parts[2] if len(parts) > 2 else None
    return parts[0], parts[1], offset


def collect(item, acc=[]):
    """Append item to acc and return acc. Starts a new list when acc is omitted."""
    acc.append(item)
    return acc
R

cat > src/parse.py <<'R'
"""Parse log timestamps into UTC datetimes."""
from datetime import datetime, timezone

from util import collect, split_stamp


def parse_many(lines):
    """Parse every line, skipping the ones that do not parse.

    Ctrl-C (KeyboardInterrupt) must still stop the run.
    """
    out = []
    for line in lines:
        try:
            collect(parse_date(line), out)
        except:
            pass
    return out


def parse_date(text):
    """Parse 'YYYY-MM-DD HH:MM +HHMM' and return the moment in UTC."""
    day, clock, offset = split_stamp(text)
    naive = datetime.strptime(day + " " + clock, "%Y-%m-%d %H:%M")
    return naive.replace(tzinfo=timezone.utc)
R

cat > tests/test_parse.py <<'R'
import os
import sys
import unittest
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
from parse import parse_date  # noqa: E402


class ParseDateTest(unittest.TestCase):
    def test_positive_offset_is_converted_to_utc(self):
        got = parse_date("2026-03-01 12:30 +0200")
        self.assertEqual(got, datetime(2026, 3, 1, 10, 30, tzinfo=timezone.utc))

    def test_negative_offset_is_converted_to_utc(self):
        got = parse_date("2026-03-01 23:15 -0500")
        self.assertEqual(got, datetime(2026, 3, 2, 4, 15, tzinfo=timezone.utc))

    def test_utc_offset_is_unchanged(self):
        got = parse_date("2026-03-01 08:00 +0000")
        self.assertEqual(got, datetime(2026, 3, 1, 8, 0, tzinfo=timezone.utc))


if __name__ == "__main__":
    unittest.main()
R

cat > test.sh <<'R'
#!/bin/sh
export PYTHONDONTWRITEBYTECODE=1
exec python3 tests/test_parse.py
R

cat > docs/found-issues.md <<'R'
# Found issues

Format: `- [status] YYYY-MM-DD path:line — symptom (suggested: fix)`. Statuses: `open`, `deferred`, `fixed`.

- [open] 2026-09-03 infra/log-rotation — the log directory is never rotated, so old timestamps pile up indefinitely, see RC-5582 (suggested: add a logrotate config)
- [open] 2026-09-05 README.md:4 — the README does not name the minimum Python version (suggested: add it under the title)
R

git init -q -b main
git config user.email eval@example.com
git config user.name eval
git add -A
git commit -q -m "initial"
