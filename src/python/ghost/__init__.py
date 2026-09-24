"""GHOST Python core — shared identity-scrubbing logic for the GHOST toolkit.

Stdlib only (no pip dependencies): base64, json, sqlite3, os, re, secrets,
sys, time, uuid. The package is invoked by the PowerShell scripts through
src/python/ghost_cli.py (repo-relative bootstrap, no PYTHONPATH needed) and
is directly importable for tests (`python -m ghost` also works).

Contract notes (must stay 1:1 with the PowerShell bridges it replaces):
- sqlite_update / delete_secrets / clear_cli_telemetry / chat_check print
  contracts are consumed by PowerShell ConvertFrom-Json / line-matching --
  do not change output shapes without updating the callers.
- Table names are validated against ^[A-Za-z_][A-Za-z0-9_]*$ before any SQL
  string interpolation; values always go through `?` placeholders.
"""

__version__ = "1.0.0"
