"""Validate an incoming orders CSV before it moves from landing/ to raw/.

usage: python -m pipelines.validate path/to/file.csv   (exit 0 = valid, 1 = quarantine)
"""
import csv
import sys
from dataclasses import dataclass, field
from datetime import date
from decimal import Decimal, InvalidOperation

REQUIRED = ("order_id", "amount")


@dataclass
class Result:
    ok: bool = True
    errors: list = field(default_factory=list)

    def fail(self, msg):
        self.ok = False
        self.errors.append(msg)


def validate(rows):
    result = Result()
    if not rows:
        result.fail("file has no data rows")
        return result

    missing = [c for c in REQUIRED if c not in rows[0]]
    if missing:
        result.fail(f"missing columns: {', '.join(missing)}")
        return result

    seen = set()
    for n, row in enumerate(rows, start=2):  # line 1 is the header
        oid = (row.get("order_id") or "").strip()
        if not oid:
            result.fail(f"line {n}: order_id is empty")
        elif oid in seen:
            result.fail(f"line {n}: duplicate order_id {oid}")
        seen.add(oid)

        try:
            if Decimal(row.get("amount") or "") < 0:
                result.fail(f"line {n}: amount is negative")
        except InvalidOperation:
            result.fail(f"line {n}: amount {row.get('amount')!r} is not a number")

        if row.get("order_date"):
            try:
                date.fromisoformat(row["order_date"])
            except ValueError:
                result.fail(f"line {n}: order_date {row['order_date']!r} is not YYYY-MM-DD")
    return result


def validate_file(path):
    with open(path, newline="", encoding="utf-8-sig") as f:
        return validate(list(csv.DictReader(f)))


if __name__ == "__main__":
    res = validate_file(sys.argv[1])
    for e in res.errors:
        print(e, file=sys.stderr)
    sys.exit(0 if res.ok else 1)
