from pathlib import Path

from pipelines.validate import validate, validate_file

SAMPLES = Path(__file__).resolve().parents[1] / "samples"


def test_rejects_missing_order_id():
    rows = [{"order_id": "", "amount": "10.00"}]
    result = validate(rows)
    assert not result.ok
    assert "order_id" in result.errors[0]


def test_accepts_good_file():
    rows = [{"order_id": "A1", "amount": "10.00"}]
    assert validate(rows).ok


def test_rejects_missing_column():
    result = validate([{"order_id": "A1"}])
    assert result.errors == ["missing columns: amount"]


def test_rejects_empty_file():
    assert not validate([]).ok


def test_sample_good_file_passes():
    assert validate_file(SAMPLES / "orders.csv").ok


def test_sample_bad_file_reports_every_problem():
    errors = validate_file(SAMPLES / "orders_bad.csv").errors
    assert any("order_id is empty" in e for e in errors)
    assert any("duplicate order_id" in e for e in errors)
    assert any("not a number" in e for e in errors)
    assert any("not YYYY-MM-DD" in e for e in errors)
