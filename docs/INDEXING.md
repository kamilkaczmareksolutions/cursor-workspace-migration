# Re-indexing after path change

Semantic tools bind indexes to **absolute paths**. Moving a folder does not automatically move embeddings or graph DB paths.

## claude-context (Zilliz / Milvus)

- Each indexed codebase is keyed by path hash in the vector store.
- After migration, run **`index_codebase`** (MCP or CLI) on the new absolute path.
- Old collections may remain orphaned in Milvus — safe to clean up later.
- Quick check: MCP `get_indexing_status` with the new path.

Typical MCP flow in a new chat:

1. `get_indexing_status` → not indexed
2. `index_codebase` on `...\YourProject\subfolder`
3. `search_code` smoke test

Environment (`~/.context/.env`, Milvus, API keys) is **outside** this repo.

## CodeGraph (`.codegraph/`)

If you use `@colbymchenry/codegraph` inside a subfolder:

1. Open that subfolder in Cursor (or set workspace root accordingly).
2. Run `npx -y @colbymchenry/codegraph init -i` in the directory containing `.codegraph/`.
3. MCP `codegraph sync` if your setup uses periodic sync.

`${workspaceFolder}` in MCP config resolves to whatever folder you opened — open the correct root after migration.

## claude-mem (global memory)

Session memory is usually **global** (separate install, e.g. `~/claude-mem`). Old sessions may still be searchable by content; new sessions tag the new project path. No migration of SQLite is required for basic continuity.
