import json
import sys
from pathlib import Path

import pandas as pd
import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from flood_ml.features import build_features, clean_readings  # noqa: E402
from flood_ml.practice_data import make_practice_readings  # noqa: E402
from flood_ml.train import evaluate, time_split, train_model  # noqa: E402

NOW = pd.Timestamp("2026-11-17T03:00:00Z")


@pytest.fixture(scope="session")
def stations():
    return json.loads((ROOT / "stations.json").read_text())


@pytest.fixture(scope="session")
def raw(stations):
    return make_practice_readings(stations, end=NOW)


@pytest.fixture(scope="session")
def clean(raw):
    return clean_readings(raw)


@pytest.fixture(scope="session")
def trained(clean, stations):
    train, test, cutoff = time_split(build_features(clean, stations))
    model = train_model(train)
    return {"model": model, "train": train, "test": test, "cutoff": cutoff,
            "metrics": evaluate(model, test, stations)}
