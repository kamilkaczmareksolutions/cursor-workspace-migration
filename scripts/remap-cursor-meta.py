"""
Remap composer.composerHeaders + sync workspaceStorage after folder move.
Param-driven (no migration.config.json required). Requires Cursor to be quit.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import sys
from datetime import datetime
from pathlib import Path


def backup(path: Path) -> Path:
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    dest = path.parent / f"{path.name}.bak-meta-{ts}"
    if path.is_dir():
        shutil.copytree(path, dest)
    else:
        shutil.copy2(path, dest)
    return dest


def uri_from_folder(folder_fs: str, folder_uri: str | None = None) -> dict:
    path = "/" + folder_fs.replace("\\", "/").lstrip("/")
    if path.startswith("//"):
        path = path[1:]
    return {
        "fsPath": folder_fs,
        "_sep": 1,
        "external": folder_uri or "",
        "path": path,
        "scheme": "file",
        "$mid": 1,
    }


def replace_paths_in_json(
    obj,
    old_fs: str,
    new_fs: str,
    old_uri: str,
    new_uri: str,
    old_path: str,
    new_path: str,
):
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
        return [
            replace_paths_in_json(x, old_fs, new_fs, old_uri, new_uri, old_path, new_path)
            for x in obj
        ]
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


def sync_workspace_storage(
    old_dir: Path, new_dir: Path, folder_uri: str, dry_run: bool = False
) -> None:
    if not old_dir.is_dir():
        raise RuntimeError(f"Old workspaceStorage missing: {old_dir}")

    if dry_run:
        print(f"  [dry-run] would copy workspaceStorage {old_dir.name} -> {new_dir.name}")
        return

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


def patch_workspace_db_paths(
    db_path: Path,
    old_fs: str,
    new_fs: str,
    old_ws: str,
    new_ws: str,
    old_uri: str,
    new_uri: str,
    dry_run: bool = False,
) -> None:
    if dry_run:
        print(f"  [dry-run] would patch paths in {db_path}")
        return

    con = sqlite3.connect(db_path)
    rows = con.execute("SELECT key, value FROM ItemTable").fetchall()
    old_path = "/" + old_fs.replace("\\", "/").lstrip("/")
    new_path = "/" + new_fs.replace("\\", "/").lstrip("/")
    patched = 0
    for key, val in rows:
        if not isinstance(val, str):
            continue
        if old_fs not in val and old_ws not in val and (not old_uri or old_uri not in val):
            continue
        try:
            obj = json.loads(val)
            new_val = json.dumps(
                replace_paths_in_json(
                    obj, old_fs, new_fs, old_uri, new_uri, old_path, new_path
                ),
                ensure_ascii=False,
            )
        except json.JSONDecodeError:
            new_val = val.replace(old_fs, new_fs).replace(old_ws, new_ws)
            if old_uri:
                new_val = new_val.replace(old_uri, new_uri)
        con.execute("UPDATE ItemTable SET value=? WHERE key=?", (new_val, key))
        patched += 1
    con.commit()
    con.close()
    print(f"  patched {patched} keys in workspace state.vscdb")


def count_headers_for_workspace(global_db: Path, ws_hash: str) -> int:
    if not global_db.is_file():
        return 0
    con = sqlite3.connect(global_db)
    row = con.execute(
        "SELECT value FROM ItemTable WHERE key='composer.composerHeaders'"
    ).fetchone()
    con.close()
    if not row:
        return 0
    raw = row[0]
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8")
    data = json.loads(raw)
    return sum(
        1
        for c in data.get("allComposers", [])
        if c.get("type") == "head"
        and (c.get("workspaceIdentifier") or {}).get("id") == ws_hash
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Remap Cursor chat metadata after folder move")
    parser.add_argument("--source", required=True, help="Source folder absolute path")
    parser.add_argument("--dest", required=True, help="Destination folder absolute path")
    parser.add_argument("--old-ws", required=True, help="Old workspaceStorage hash")
    parser.add_argument("--new-ws", required=True, help="New workspaceStorage hash")
    parser.add_argument("--dest-uri", required=True, help="Destination folder URI (file:///...)")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    old_fs = args.source
    new_fs = args.dest
    old_ws = args.old_ws
    new_ws = args.new_ws
    folder_uri = args.dest_uri
    new_uri = uri_from_folder(new_fs, folder_uri)
    dry = args.dry_run

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

    old_count = count_headers_for_workspace(global_db, old_ws)
    print(f"Threads bound to old workspace: {old_count}")

    if dry:
        print("[dry-run] would backup global state.vscdb")
        print("[dry-run] would remap composer.composerHeaders")
        remapped, ghosts, total = 0, 0, 0
    else:
        print("Backup global state.vscdb...")
        backup(global_db)

        print("Remap composer.composerHeaders...")
        con = sqlite3.connect(global_db)
        remapped, ghosts, total = fix_global_headers(con, old_ws, new_ws, new_uri)
        con.commit()
        con.close()

    print(f"  remapped: {remapped}, ghosts removed: {ghosts}, headers total: {total}")

    print("Full workspaceStorage sync...")
    sync_workspace_storage(old_ws_dir, new_ws_dir, folder_uri, dry_run=dry)

    print("Patch paths in workspace state.vscdb...")
    patch_workspace_db_paths(
        new_ws_dir / "state.vscdb",
        old_fs,
        new_fs,
        old_ws,
        new_ws,
        old_uri,
        folder_uri,
        dry_run=dry,
    )

    if not dry:
        new_count = count_headers_for_workspace(global_db, new_ws)
        print(f"Threads bound to new workspace: {new_count}")
        if new_count < old_count:
            print(
                f"WARN: new count {new_count} < old count {old_count}",
                file=sys.stderr,
            )

    print("OK.")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
