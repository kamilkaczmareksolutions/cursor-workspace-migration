"""
Remap composer.composerHeaders + sync workspaceStorage after folder move.
Requires Cursor to be quit. Reads migration.config.json from repo root.
"""
from __future__ import annotations

import json
import os
import shutil
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
CONFIG_PATH = REPO_ROOT / "migration.config.json"


def load_config() -> dict:
    if not CONFIG_PATH.is_file():
        raise RuntimeError(
            f"Missing {CONFIG_PATH}\nCopy migration.config.example.json and fill values."
        )
    with CONFIG_PATH.open(encoding="utf-8") as f:
        return json.load(f)


def uri_from_folder(cfg: dict) -> dict:
    ext = cfg.get("destination_folder_uri") or ""
    fs = cfg["destination_folder"]
    path = "/" + fs.replace("\\", "/").lstrip("/")
    if path.startswith("//"):
        path = path[1:]
    return {
        "fsPath": fs,
        "_sep": 1,
        "external": ext,
        "path": path,
        "scheme": "file",
        "$mid": 1,
    }


def backup(path: Path) -> Path:
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    dest = path.parent / f"{path.name}.bak-meta-{ts}"
    if path.is_dir():
        shutil.copytree(path, dest)
    else:
        shutil.copy2(path, dest)
    return dest


def replace_paths_in_json(obj, old_fs: str, new_fs: str, old_uri: str, new_uri: str, old_path: str, new_path: str):
    if isinstance(obj, str):
        s = obj
        s = s.replace(old_fs, new_fs)
        s = s.replace(old_fs.replace("\\", "/"), new_fs.replace("\\", "/"))
        if old_uri:
            s = s.replace(old_uri, new_uri)
        if old_path:
            s = s.replace(old_path, new_path)
        return s
    if isinstance(obj, list):
        return [replace_paths_in_json(x, old_fs, new_fs, old_uri, new_uri, old_path, new_path) for x in obj]
    if isinstance(obj, dict):
        return {
            k: replace_paths_in_json(v, old_fs, new_fs, old_uri, new_uri, old_path, new_path)
            for k, v in obj.items()
        }
    return obj


def fix_global_headers(con, old_ws: str, new_ws: str, new_uri: dict) -> tuple[int, int, int]:
    row = con.execute(
        "SELECT value FROM ItemTable WHERE key='composer.composerHeaders'"
    ).fetchone()
    if not row:
        raise RuntimeError("Missing composer.composerHeaders in global state.vscdb")

    raw = row[0]
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8")
    data = json.loads(raw)
    composers = data.get("allComposers", [])

    remapped = 0
    removed_ghosts = 0
    kept = []

    for c in composers:
        if c.get("type") != "head":
            kept.append(c)
            continue

        wi = c.get("workspaceIdentifier") or {}
        wid = wi.get("id")

        if wid == new_ws and not c.get("name"):
            removed_ghosts += 1
            print(f"  removed ghost: {c.get('composerId')}")
            continue

        if wid == old_ws:
            wi["id"] = new_ws
            wi["uri"] = dict(new_uri)
            c["workspaceIdentifier"] = wi
            c["isDraft"] = False
            remapped += 1

        kept.append(c)

    data["allComposers"] = kept
    new_val = json.dumps(data, ensure_ascii=False)
    con.execute(
        "UPDATE ItemTable SET value=? WHERE key='composer.composerHeaders'",
        (new_val,),
    )
    return remapped, removed_ghosts, len(kept)


def sync_workspace_storage(old_dir: Path, new_dir: Path, folder_uri: str):
    if not old_dir.is_dir():
        raise RuntimeError(f"Old workspaceStorage missing: {old_dir}")

    if new_dir.is_dir():
        backup(new_dir)
        shutil.rmtree(new_dir)

    shutil.copytree(old_dir, new_dir)
    ws_json = new_dir / "workspace.json"
    ws_json.write_text(
        json.dumps({"folder": folder_uri}, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"  copied workspaceStorage {old_dir.name} -> {new_dir.name}")


def patch_workspace_db_paths(db_path: Path, old_fs: str, new_fs: str, old_ws: str, new_ws: str, old_uri: str, new_uri: str):
    con = sqlite3.connect(db_path)
    rows = con.execute("SELECT key, value FROM ItemTable").fetchall()
    old_path = "/" + old_fs.replace("\\", "/").lstrip("/")
    new_path = "/" + new_fs.replace("\\", "/").lstrip("/")
    for key, val in rows:
        if not isinstance(val, str):
            continue
        if old_fs not in val and old_ws not in val and (not old_uri or old_uri not in val):
            continue
        try:
            obj = json.loads(val)
            new_val = json.dumps(
                replace_paths_in_json(obj, old_fs, new_fs, old_uri, new_uri, old_path, new_path),
                ensure_ascii=False,
            )
        except json.JSONDecodeError:
            new_val = val.replace(old_fs, new_fs).replace(old_ws, new_ws)
            if old_uri:
                new_val = new_val.replace(old_uri, new_uri)
        con.execute("UPDATE ItemTable SET value=? WHERE key=?", (new_val, key))
    con.commit()
    con.close()


def main():
    cfg = load_config()
    old_ws = cfg["old_workspace_hash"]
    new_ws = cfg["new_workspace_hash"]
    old_fs = cfg["source_folder"]
    new_fs = cfg["destination_folder"]
    folder_uri = cfg["destination_folder_uri"]
    new_uri = uri_from_folder(cfg)

    appdata = Path(os.environ["APPDATA"]) / "Cursor" / "User"
    global_db = appdata / "globalStorage" / "state.vscdb"
    old_ws_dir = appdata / "workspaceStorage" / old_ws
    new_ws_dir = appdata / "workspaceStorage" / new_ws

    if not global_db.is_file():
        raise RuntimeError(f"Missing {global_db}")

    old_uri = ""
    old_wj = old_ws_dir / "workspace.json"
    if old_wj.is_file():
        try:
            old_uri = json.loads(old_wj.read_text(encoding="utf-8")).get("folder", "")
        except json.JSONDecodeError:
            pass

    print("Backup global state.vscdb...")
    backup(global_db)

    print("Remap composer.composerHeaders...")
    con = sqlite3.connect(global_db)
    remapped, ghosts, total = fix_global_headers(con, old_ws, new_ws, new_uri)
    con.commit()
    con.close()
    print(f"  remapped: {remapped}, ghosts removed: {ghosts}, headers: {total}")

    print("Full workspaceStorage sync...")
    sync_workspace_storage(old_ws_dir, new_ws_dir, folder_uri)

    print("Patch paths in workspace state.vscdb...")
    patch_workspace_db_paths(
        new_ws_dir / "state.vscdb",
        old_fs,
        new_fs,
        old_ws,
        new_ws,
        old_uri,
        folder_uri,
    )

    print("OK. Quit and reopen Cursor -> open destination folder.")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
