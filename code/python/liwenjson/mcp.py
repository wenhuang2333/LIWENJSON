"""Console entry point for an MCP client: `liwenjson-mcp`.

The MCP server itself is implemented in the MoonBit binary (`liwenjson mcp`);
this module only resolves the binary and replaces the process with it, so
stdin/stdout remain a clean JSON-RPC channel with no Python in the middle.

    {"mcpServers": {"liwenjson": {"command": "liwenjson-mcp"}}}
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from .client import _make_executable, _platform_key, find_binary

__all__ = ["main", "cli_main"]


def _engine_binary() -> str:
    binary = find_binary()
    launcher = Path(sys.argv[0]).resolve()
    # Once pip installs `liwenjson`, find_binary() may find this Python
    # launcher on PATH. Never exec it recursively: use the wheel's engine.
    launchers = {
        launcher,
        launcher.with_name("liwenjson"),
        launcher.with_name("liwenjson.exe"),
    }
    if Path(binary).resolve() not in {path.resolve() for path in launchers}:
        return binary
    here = Path(__file__).resolve().parent
    key = _platform_key()
    directories = [here / "bin" / key] if key is not None else []
    directories.append(here / "bin")
    for directory in directories:
        for name in ("liwenjson", "liwenjson.exe"):
            candidate = directory / name
            if candidate.is_file():
                _make_executable(candidate)
                return str(candidate)
    raise FileNotFoundError(
        "the liwenjson launcher has no bundled engine for this platform; "
        "install a wheel carrying it or set LIWENJSON_BIN to a native executable"
    )


def cli_main() -> None:
    """Expose the native CLI unchanged, including commands printed in configs."""
    binary = _engine_binary()
    os.execv(binary, [binary, *sys.argv[1:]])


def main() -> None:
    binary = _engine_binary()
    os.execv(binary, [binary, "mcp", *sys.argv[1:]])


if __name__ == "__main__":
    main()
