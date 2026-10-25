"""Independent protobuf byte fixtures, Python stdlib only; public test data.

Run from the repository root after reviewing spec/vectors/relay-auth.json.
This does not generate credentials, perform network I/O, or implement E2EE.
"""

import base64
import hashlib
import json
from pathlib import Path


def varint(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def protobuf(fields):
    result = bytearray()
    for key, value in sorted(fields.items()):
        if isinstance(value, int):
            result += varint(key << 3) + varint(value)
        else:
            value = value.encode() if isinstance(value, str) else value
            result += varint((key << 3) | 2) + varint(len(value)) + value
    return bytes(result)


root = Path(__file__).resolve().parents[1]
auth = json.loads((root / "spec/vectors/relay-auth.json").read_text())
challenge = {
    4: base64.b64decode(auth["client_nonce"]),
    5: auth["relay_id"],
    6: auth["session_id"],
    7: base64.b64decode(auth["challenge"]),
    8: auth["expires_at"],
}
packet = protobuf({
    1: auth["device_id"],
    2: "22222222-2222-4222-8222-222222222222",
    3: "55555555-5555-4555-8555-555555555555",
    4: "018bcfe5-6800-7000-8000-000000000001",
    5: bytes([1, 2, 3]),  # Symbolic bytes, not an encryption vector.
    6: "bridge-relay-e2ee-v1",
    7: 1,
})
frames = {
    "hello": {1: 1, 2: 1, 3: auth["device_id"], 4: challenge[4]},
    "challenge": {1: 1, 2: 2, **challenge},
    "authenticate": {1: 1, 2: 3, 3: auth["device_id"], **challenge,
                     9: base64.b64decode(auth["signature"])},
    "ready": {1: 1, 2: 4, 3: auth["device_id"], 6: auth["session_id"]},
    "submit": {1: 1, 2: 5, 10: packet},
    "forwarded": {1: 1, 2: 6, 11: "018bcfe5-6800-7000-8000-000000000001",
                  12: hashlib.sha256(packet).digest()},
    "deliver": {1: 1, 2: 7, 10: packet},
    "unavailable": {1: 1, 2: 8, 11: "018bcfe5-6800-7000-8000-000000000001",
                    12: hashlib.sha256(packet).digest()},
    "auth_rejected": {1: 1, 2: 9},
}
output = json.dumps({
    "warning": "PUBLIC TEST DATA. Packet bytes are symbolic, not an E2EE vector.",
    "frames_hex": {name: protobuf(fields).hex() for name, fields in frames.items()},
}, indent=2, sort_keys=True) + "\n"
for destination in ["spec/vectors/relay-wire.json", "Tests/Fixtures/relay-wire.json"]:
    (root / destination).write_text(output)
