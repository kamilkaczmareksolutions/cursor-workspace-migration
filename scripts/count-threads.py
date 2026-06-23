"""Count composer header threads for a workspace hash. Prints: count|ghosts|named"""
from __future__ import annotations

import json
import os
import sqlite3
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) < 2:
        print("0|0|0", file=sys.stderr)
        sys.exit(1)

    ws = sys.argv[1]
    db = Path(os.environ["APPDATA"]) / "Cursor" / "User" / "globalStorage" / "state.vscdb"
    if not db.is_file():
        print("0|0|0")
        return

    con = sqlite3.connect(db)
    row = con.execute(
        "SELECT value FROM ItemTable WHERE key='composer.composerHeaders'"
    ).fetchone()
    con.close()

    if not row:
        print("0|0|0")
        return

    raw = row[0]
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8")
    data = json.loads(raw)

    count = 0
    ghosts = 0
    named = 0
    for c in data.get("allComposers", []):
        if c.get("type") != "head":
            continue
        wi = c.get("workspaceIdentifier") or {}
        if wi.get("id") != ws:
            continue
        count += 1
        if c.get("name"):
            named += 1
        else:
            ghosts += 1

    print(f"{count}|{ghosts}|{named}")


if __name__ == "__main__":
    main()
