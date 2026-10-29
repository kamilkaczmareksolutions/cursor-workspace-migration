"""Fake Cursor data for the Windows E2E test.

  make SRC DST  build the fixture under %APPDATA% / %USERPROFILE% (must be C:\\cwm-test\\fake)
  dump          print workspace.json files and ItemTable contents as JSON
"""
from __future__ import annotations

import json
import os
import sqlite3
import sys
from pathlib import Path

OLD_WS = "a" * 32
NEW_WS = "b" * 32
OTHER_WS = "c" * 32


def vscode_uri(fs_path: str) -> str:
    # What Cursor/VS Code writes: lowercase drive, ':' as %3A, '/' kept
    drive, rest = fs_path[0].lower(), fs_path[2:].replace("\\", "/")
    return f"file:///{drive}%3A{rest}"


def make_db(path: Path, items: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
    con.executemany("INSERT INTO ItemTable VALUES (?, ?)", items.items())
    con.commit()
    con.close()


def header(cid: str, name: str | None, ws: str, folder: str) -> dict:
    h = {
        "type": "head",
        "composerId": cid,
        "workspaceIdentifier": {
            "id": ws,
            "uri": {"fsPath": folder, "external": vscode_uri(folder), "scheme": "file", "$mid": 1},
        },
    }
    if name:
        h["name"] = name
    return h


def read_db(path: Path) -> dict:
    con = sqlite3.connect(path)
    rows = con.execute("SELECT key, value FROM ItemTable").fetchall()
    con.close()
    return {k: (v.decode("utf-8") if isinstance(v, bytes) else v) for k, v in rows}


def dump() -> None:
    user = Path(os.environ["APPDATA"]) / "Cursor" / "User"
    out = {"workspaces": {}, "global": read_db(user / "globalStorage" / "state.vscdb")}
    for d in sorted((user / "workspaceStorage").iterdir()):
        entry = {}
        if (d / "workspace.json").is_file():
            entry["folder"] = json.loads((d / "workspace.json").read_text(encoding="utf-8"))["folder"]
        if (d / "state.vscdb").is_file():
            entry["items"] = read_db(d / "state.vscdb")
        out["workspaces"][d.name] = entry
    sys.stdout.reconfigure(encoding="utf-8")
    print(json.dumps(out, ensure_ascii=True))


def make(src: str, dst: str) -> None:
    appdata = Path(os.environ["APPDATA"])
    profile = Path(os.environ["USERPROFILE"])
    for p in (appdata, profile):
        if not str(p).lower().startswith("c:\\cwm-test\\fake"):
            raise SystemExit(f"refusing to write fixture outside C:\\cwm-test\\fake: {p}")

    user = appdata / "Cursor" / "User"
    ws_root = user / "workspaceStorage"
    for ws, folder in ((OLD_WS, src), (NEW_WS, dst), (OTHER_WS, r"C:\cwm-test\z\app")):
        d = ws_root / ws
        d.mkdir(parents=True, exist_ok=True)
        (d / "workspace.json").write_text(json.dumps({"folder": vscode_uri(folder)}), encoding="utf-8")

    src_file = src + "\\README.md"
    make_db(ws_root / OLD_WS / "state.vscdb", {
        "memento/workbench.editors": json.dumps({"files": [src_file, vscode_uri(src) + "/README.md"]}),
        "workbench.panel.chat": json.dumps({"workspace": OLD_WS}),
    })
    make_db(ws_root / NEW_WS / "state.vscdb", {"memento/fresh": "{}"})
    make_db(ws_root / OTHER_WS / "state.vscdb", {"memento/other": "{}"})

    headers = {"allComposers": [
        header("c1", "Chat one", OLD_WS, src),
        header("c2", "Czat zażółć", OLD_WS, src),
        header("c3", None, NEW_WS, dst),            # fresh "New Chat" tab: ghost
        header("c4", "Other project", OTHER_WS, r"C:\cwm-test\z\app"),
    ]}
    make_db(user / "globalStorage" / "state.vscdb", {
        "composer.composerHeaders": json.dumps(headers, ensure_ascii=False),
    })

    projects = profile / ".cursor" / "projects"
    tr = projects / "c-cwm-test-a-app" / "agent-transcripts"
    (tr / "sub").mkdir(parents=True, exist_ok=True)
    (tr / "t1.jsonl").write_text('{"role":"user","text":"hello"}\n', encoding="utf-8")
    (tr / "t2.jsonl").write_text('{"role":"user","text":"zażółć gęślą jaźń"}\n', encoding="utf-8")
    (tr / "sub" / "t3.txt").write_text("nested\n", encoding="utf-8")
    # Decoys: same basename, other parent / basename prefix. Must never be picked.
    for decoy in ("c-cwm-test-z-app", "c-cwm-test-a-application"):
        d = projects / decoy / "agent-transcripts"
        d.mkdir(parents=True, exist_ok=True)
        (d / "decoy.jsonl").write_text("{}\n", encoding="utf-8")

    print(f"fixture ready: old_ws={OLD_WS} new_ws={NEW_WS}")


if __name__ == "__main__":
    if sys.argv[1] == "make":
        make(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "dump":
        dump()
    else:
        raise SystemExit(__doc__)
