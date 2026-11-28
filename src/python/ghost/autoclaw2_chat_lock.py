"""Serialize GHOST chat writers for one Windows user (POSIX for fixtures)."""

from contextlib import contextmanager
import hashlib
import os
from pathlib import Path


@contextmanager
def chat_writer(home):
    from ghost.autoclaw2 import Refusal

    if os.name != "nt":
        import fcntl
        path = Path(home) / ".ghost-autoclaw2-chat-mesh.lock"
        with path.open("ab") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise Refusal("mesh-busy", "another chat sync is running; retry shortly") from exc
            yield
        return

    import ctypes as c
    from ctypes import wintypes as w

    k32 = c.WinDLL("kernel32", use_last_error=True)
    k32.CreateMutexW.argtypes = (c.c_void_p, w.BOOL, w.LPCWSTR)
    k32.CreateMutexW.restype = w.HANDLE
    k32.WaitForSingleObject.argtypes = (w.HANDLE, w.DWORD)
    k32.WaitForSingleObject.restype = w.DWORD
    k32.CloseHandle.argtypes = k32.ReleaseMutex.argtypes = (w.HANDLE,)
    key = hashlib.sha256(os.path.normcase(home).encode("utf-8")).hexdigest()[:20]
    handle = k32.CreateMutexW(None, False, "Local\\GhostAutoClaw2ChatMesh-" + key)
    if not handle:
        raise Refusal("mesh-lock-failed", "could not acquire the local chat sync lock")
    try:
        if k32.WaitForSingleObject(handle, 20000) not in (0, 0x80):
            raise Refusal("mesh-busy", "another chat sync is running; retry shortly")
        try:
            yield
        finally:
            k32.ReleaseMutex(handle)
    finally:
        k32.CloseHandle(handle)
