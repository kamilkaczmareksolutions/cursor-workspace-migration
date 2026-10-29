"""Unit tests for scripts/remap-cursor-meta.py. Run: python -m unittest discover -s tests"""
from __future__ import annotations

import importlib.util
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

_SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "remap-cursor-meta.py"
_spec = importlib.util.spec_from_file_location("remap_cursor_meta", _SCRIPT)
remap = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(remap)

OLD_WS = "a" * 32
NEW_WS = "b" * 32
OLD_FS = r"C:\cwm-test\a\app"
NEW_FS = r"C:\cwm-test\b\app"
OLD_URI = "file:///c%3A/cwm-test/a/app"
NEW_URI = "file:///c%3A/cwm-test/b/app"


class ReplaceWsHashTest(unittest.TestCase):
    def test_replaces_exact_and_delimited_hash(self):
        for before, after in [
            (OLD_WS, NEW_WS),
            (f"ws:{OLD_WS}", f"ws:{NEW_WS}"),
            (f"{OLD_WS}/state", f"{NEW_WS}/state"),
            (f"x-{OLD_WS}-y {OLD_WS}", f"x-{NEW_WS}-y {NEW_WS}"),
        ]:
            self.assertEqual(remap.replace_ws_hash(before, OLD_WS, NEW_WS), after)

    def test_leaves_longer_tokens_alone(self):
        for s in (OLD_WS + "0", "f" + OLD_WS, "a" * 33):
            self.assertEqual(remap.replace_ws_hash(s, OLD_WS, NEW_WS), s)

    def test_empty_old_hash_is_a_no_op(self):
        self.assertEqual(remap.replace_ws_hash("abc", "", NEW_WS), "abc")


class ReplacePathsInJsonTest(unittest.TestCase):
    def test_hash_in_nested_values_and_keys(self):
        obj = {
            "workspace": OLD_WS,
            "byWorkspace": {OLD_WS: {"id": OLD_WS, "n": 3}},
            "list": [f"ws:{OLD_WS}", OLD_WS + "ff", 7, None, True],
        }
        out = remap.replace_paths_in_json(obj, OLD_FS, NEW_FS, OLD_URI, NEW_URI, "", "", OLD_WS, NEW_WS)
        self.assertEqual(out, {
            "workspace": NEW_WS,
            "byWorkspace": {NEW_WS: {"id": NEW_WS, "n": 3}},
            "list": [f"ws:{NEW_WS}", OLD_WS + "ff", 7, None, True],
        })

    def test_without_hash_arguments_hash_is_kept(self):
        out = remap.replace_paths_in_json({"w": OLD_WS}, OLD_FS, NEW_FS, OLD_URI, NEW_URI, "", "")
        self.assertEqual(out, {"w": OLD_WS})


class PatchWorkspaceDbTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = Path(self.tmp.name) / "state.vscdb"
        con = sqlite3.connect(self.db)
        con.execute("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
        con.executemany("INSERT INTO ItemTable VALUES (?, ?)", [
            ("chat", json.dumps({"workspace": OLD_WS, "decoy": OLD_WS + "0", "name": "zażółć"}, ensure_ascii=False)),
            ("editors", json.dumps({"files": [OLD_FS + r"\README.md", OLD_URI + "/README.md"]})),
            ("plain", f"not json {OLD_WS} {OLD_FS}"),
            ("other", json.dumps({"w": "c" * 32})),
        ])
        con.commit()
        con.close()

    def tearDown(self):
        self.tmp.cleanup()

    def read(self):
        con = sqlite3.connect(self.db)
        rows = dict(con.execute("SELECT key, value FROM ItemTable").fetchall())
        con.close()
        return rows

    def test_patches_hash_inside_json_and_keeps_json_valid(self):
        before_other = self.read()["other"]
        remap.patch_workspace_db_paths(self.db, OLD_FS, NEW_FS, OLD_WS, NEW_WS, OLD_URI, NEW_URI)
        rows = self.read()

        chat = json.loads(rows["chat"])
        self.assertEqual(chat, {"workspace": NEW_WS, "decoy": OLD_WS + "0", "name": "zażółć"})
        self.assertEqual(json.loads(rows["editors"]), {"files": [NEW_FS + r"\README.md", NEW_URI + "/README.md"]})
        self.assertEqual(rows["plain"], f"not json {NEW_WS} {NEW_FS}")
        self.assertEqual(rows["other"], before_other)

    def test_dry_run_writes_nothing(self):
        before = self.db.read_bytes()
        remap.patch_workspace_db_paths(self.db, OLD_FS, NEW_FS, OLD_WS, NEW_WS, OLD_URI, NEW_URI, dry_run=True)
        self.assertEqual(self.db.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
