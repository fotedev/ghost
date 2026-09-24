r"""Bootstrap launcher for the GHOST Python core.

The PowerShell scripts invoke this file by absolute path:
    & $python.Source <repo>\src\python\ghost_cli.py <command> ...
It inserts its own directory on sys.path and delegates to ghost.__main__,
so callers need neither PYTHONPATH nor a specific working directory.
`python -m ghost` from src/python remains equally supported.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ghost.__main__ import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
