from pathlib import Path

from politick_driver import log as logmod


def test_entry_bytes_match_kernel_format():
    e = logmod.Entry(tick=2, seq=5, kind="event", payload={"name": "petition", "args": [1, "north"]})
    assert (
        logmod.dumps_entry(e)
        == '{"tick":2,"seq":5,"kind":"event","payload":{"name":"petition","args":[1,"north"]}}'
    )


def test_roundtrip(tmp_path: Path):
    path = tmp_path / "w.ndjson"
    logmod.create_log(path, [{"add_schema": {"name": "s", "fields": [["id", "symbol"]], "key": 1}}])
    logmod.append_entries(path, [logmod.Entry(1, 2, "event", {"name": "x", "args": []})])

    entries = logmod.read_log(path)
    assert [e.kind for e in entries] == ["diff", "event"]
    assert logmod.next_seq(entries) == 3
    assert path.read_text().startswith('{"format":1}\n')
