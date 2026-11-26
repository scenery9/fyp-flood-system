"""TP101 forecast.json signer: same bytes and signature as the app expects.

The fixtures were made by Node's own Ed25519 (an independent implementation)
from a fixed TEST key and are the ones the Dart verifier is tested with
(packages/flood_core/test/fixtures/signed), so this proves Python signs
exactly what the app checks.
"""
import base64
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from flood_ml.sign import keygen, public_key_b64, sign_bytes, sign_file, verify_bytes  # noqa: E402

FIX = ROOT.parent / "packages" / "flood_core" / "test" / "fixtures" / "signed"
KEYS = json.loads((FIX / "keys.json").read_text())
BODY = (FIX / "forecast.json").read_bytes()
SIG = json.loads((FIX / "forecast.json.sig").read_text())


def test_same_signature_as_the_app_fixture():
    # Ed25519 is deterministic: same key and bytes give the same signature.
    assert public_key_b64(KEYS["test_seed"]) == KEYS["test_public_key"]
    assert sign_bytes(BODY, KEYS["test_seed"]) == SIG["signature"]


def test_sign_file_writes_the_sig_file_the_app_reads(tmp_path):
    f = tmp_path / "forecast.json"
    f.write_bytes(BODY)
    out = sign_file(f, KEYS["test_seed"], "test-2026-1")
    assert out.name == "forecast.json.sig"
    assert json.loads(out.read_text()) == {"alg": "Ed25519", "key_id": "test-2026-1", "signature": SIG["signature"]}


def test_changed_bytes_and_other_keys_do_not_verify():
    assert verify_bytes(BODY, SIG["signature"], KEYS["test_public_key"])
    assert not verify_bytes(BODY + b" ", SIG["signature"], KEYS["test_public_key"])
    assert not verify_bytes(BODY, SIG["signature"], KEYS["attacker_public_key"])
    assert not verify_bytes(BODY, KEYS["signature_without_prefix"], KEYS["test_public_key"])


def test_new_keys_are_random_and_work():
    (s1, p1), (s2, p2) = keygen(), keygen()
    assert s1 != s2 and p1 != p2
    assert len(base64.b64decode(s1)) == 32 and len(base64.b64decode(p1)) == 32
    assert verify_bytes(b"{}", sign_bytes(b"{}", s1), p1)


def test_refuses_non_ascii_and_bad_keys():
    with pytest.raises(UnicodeDecodeError):
        sign_bytes("{\"name\": \"Sg. Klang \u00e9\"}".encode(), KEYS["test_seed"])
    with pytest.raises(ValueError):
        sign_bytes(b"{}", base64.b64encode(b"short").decode())
