import json
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
KERNEL_BIN = REPO / "zig-out" / "bin" / "politick"
LEGISLATURE = REPO / "driver" / "worlds" / "legislature.json"


@pytest.fixture(scope="session")
def kernel_bin() -> Path:
    if not KERNEL_BIN.exists():
        pytest.skip("kernel binary missing — run `zig build` at the repo root")
    return KERNEL_BIN


@pytest.fixture()
def legislature_log(tmp_path) -> Path:
    """A fresh log seeded with the legislature world."""
    from politick_driver import log as logmod

    path = tmp_path / "world.ndjson"
    logmod.create_log(path, json.loads(LEGISLATURE.read_text(encoding="utf-8")))
    return path
