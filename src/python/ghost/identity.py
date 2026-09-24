"""Identity set generation — port of New-IdentitySet in identity_utils.ps1.

Value contracts (verified by tests/python/test_ghost_core.py and mirrored by
tests/identity_utils.Tests.ps1):
- devDeviceId: lowercase GUID string
- machineId:   64 hex chars  (32 random bytes, crypto RNG)
- macMachineId: 128 hex chars (64 random bytes, crypto RNG)
- sqmId:       "{UPPERCASE-GUID}" (braced, uppercase)
"""

import secrets
import uuid


def new_identity_set():
    """Return a fresh 4-field identity set. Each call yields independent IDs."""
    return {
        "devDeviceId": str(uuid.uuid4()).lower(),
        "machineId": secrets.token_hex(32),
        "macMachineId": secrets.token_hex(64),
        "sqmId": "{" + str(uuid.uuid4()).upper() + "}",
    }


def new_crash_reporter_id():
    """Port of Get-NewCrashReporterId: lowercase GUID string."""
    return str(uuid.uuid4()).lower()
