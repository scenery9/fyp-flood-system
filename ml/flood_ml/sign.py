"""Ed25519 signature for forecast.json, checked by the app before it shows a
real forecast (packages/flood_core/lib/src/security/forecast_signature.dart).

The signature covers b"FloodReady forecast.json v1\\n" + the file's exact bytes
and is written next to it as forecast.json.sig:
    {"alg": "Ed25519", "key_id": "...", "signature": "<base64>"}

Make a key once (keep the private part secret, e.g. a GitHub Actions secret):
    python -m flood_ml.sign keygen --key-id fr-2026-1
Sign a file (run.py does this itself when FORECAST_SIGNING_KEY is set):
    FORECAST_SIGNING_KEY=... FORECAST_KEY_ID=fr-2026-1 python -m flood_ml.sign sign output/forecast.json
"""
import argparse
import base64
import json
import os
import sys
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

PREFIX = b"FloodReady forecast.json v1\n"


def _private_key(seed_b64):
    seed = base64.b64decode(seed_b64, validate=True)
    if len(seed) != 32:
        raise ValueError("The signing key must be 32 bytes (base64)")
    return Ed25519PrivateKey.from_private_bytes(seed)


def public_key_b64(seed_b64):
    pub = _private_key(seed_b64).public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    return base64.b64encode(pub).decode()


def sign_bytes(data, seed_b64):
    """Base64 Ed25519 signature of PREFIX + data. The app reads forecast.json
    as text, so the file must be plain ASCII (json.dump's default)."""
    data.decode("ascii")  # raises UnicodeDecodeError otherwise
    return base64.b64encode(_private_key(seed_b64).sign(PREFIX + data)).decode()


def verify_bytes(data, signature_b64, public_b64):
    """True when the signature matches (same rule as the app)."""
    pub = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_b64))
    try:
        pub.verify(base64.b64decode(signature_b64), PREFIX + data)
        return True
    except Exception:
        return False


def sign_file(path, seed_b64, key_id):
    """Signs the file's bytes as stored and writes <path>.sig. Returns the .sig path."""
    path = Path(path)
    sig = {"alg": "Ed25519", "key_id": key_id, "signature": sign_bytes(path.read_bytes(), seed_b64)}
    out = path.with_name(path.name + ".sig")
    out.write_bytes((json.dumps(sig) + "\n").encode("ascii"))
    return out


def keygen():
    """A new random key: (private seed, public key), both base64."""
    seed = Ed25519PrivateKey.generate().private_bytes_raw()
    seed_b64 = base64.b64encode(seed).decode()
    return seed_b64, public_key_b64(seed_b64)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd")
    k = sub.add_parser("keygen", help="make a new signing key")
    k.add_argument("--key-id", default="fr-1")
    s = sub.add_parser("sign", help="sign forecast.json")
    s.add_argument("file")
    a = p.parse_args(argv)
    if a.cmd == "keygen":
        seed, pub = keygen()
        print("PRIVATE (GitHub secret FORECAST_SIGNING_KEY; never commit it):")
        print(f"  {seed}")
        print(f"PUBLIC (add to trustedForecastKeys in forecast_signature.dart):")
        print(f"  '{a.key_id}': '{pub}',")
        return 0
    if a.cmd == "sign":
        seed, key_id = os.environ.get("FORECAST_SIGNING_KEY"), os.environ.get("FORECAST_KEY_ID")
        if not seed or not key_id:
            raise SystemExit("Set FORECAST_SIGNING_KEY and FORECAST_KEY_ID")
        print(f"Signed: {sign_file(a.file, seed, key_id)}")
        return 0
    p.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
