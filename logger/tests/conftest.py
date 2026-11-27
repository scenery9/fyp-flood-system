import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
FIX = Path(__file__).resolve().parent / "fixtures"
NOW = datetime(2026, 11, 17, 7, 20, tzinfo=timezone.utc)  # 15:20 Malaysia time


def load(name):
    return json.loads((FIX / name).read_text(encoding="utf-8"))


@pytest.fixture
def wl():
    return load("wl_district_6.json")


@pytest.fixture
def rf():
    return load("rf_district_6.json")


@pytest.fixture
def lists():
    return load("wl_station_list.json"), load("rf_station_list.json")
