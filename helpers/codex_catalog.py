"""Read-only, folder-scoped Codex chat catalog helpers.

This module intentionally has no dependency on ``codex_bridge``. Callers inject
their RPC client for daemon reads and pass database paths for offline reads.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
from pathlib import Path
from urllib.parse import quote


class CatalogError(RuntimeError):
    pass


def _json_object(value):
    if isinstance(value, dict):
        return value
    if isinstance(value, str) and value.startswith("{"):
        try:
            parsed = json.loads(value)
            return parsed if isinstance(parsed, dict) else {}
        except (TypeError, ValueError):
            pass
    return {}


def guardian_review(raw):
    """Return true only for explicitly tagged guardian review threads."""
    if not isinstance(raw, dict):
        return False
    for key in ("threadSource", "thread_source"):
        if raw.get(key) == "guardian_review":
            return True
    source = _json_object(raw.get("source"))
    # The app-server uses tagged source variants. Restrict this exclusion to
    # the guardian subtype, not all subagent or agent-created conversations.
    for key in ("subAgent", "subagent"):
        variant = source.get(key)
        if isinstance(variant, dict) and variant.get("other") == "guardian":
            return True
    return False


def thread_archived(raw):
    """Read the native archived flag, including SQLite integer encodings."""
    if not isinstance(raw, dict):
        return False
    value = raw.get("archived", raw.get("isArchived", False))
    return value is True or value == 1 or value == "1"


def normalize_thread(raw):
    """Normalize a daemon or SQLite thread record into a catalog row."""
    if not isinstance(raw, dict):
        return None
    if guardian_review(raw):
        return None
    if thread_archived(raw):
        return None
    source = raw.get("source")
    if isinstance(source, dict):
        source_name = "subAgent" if "subAgent" in source or "subagent" in source else "unknown"
    else:
        source_name = source if isinstance(source, str) and source else "unknown"
    created = raw.get("createdAt", raw.get("created_at"))
    updated = raw.get("updatedAt", raw.get("updated_at"))
    if created is None and raw.get("created_at_ms") is not None:
        created = raw["created_at_ms"] / 1000
    if updated is None and raw.get("updated_at_ms") is not None:
        updated = raw["updated_at_ms"] / 1000
    status_value = raw.get("status")
    status = status_value.get("type") if isinstance(status_value, dict) else status_value
    git_info = raw.get("gitInfo")
    branch = raw.get("git_branch")
    if not branch and isinstance(git_info, dict):
        branch = git_info.get("branch")
    return {
        "id": raw.get("id"),
        "title": raw.get("name") or raw.get("title") or raw.get("preview") or raw.get("first_user_message") or "",
        "cwd": raw.get("cwd") or "",
        "status": status or "unknown",
        "source": source_name,
        "threadSource": raw.get("threadSource", raw.get("thread_source")),
        "projectId": raw.get("projectId", raw.get("project_id")),
        "createdAt": created,
        "updatedAt": updated,
        "model": raw.get("model"),
        "branch": branch or "",
        "archived": False,
    }


def filter_rows(rows, *, include_archived=False):
    """Normalize records and apply guardian/archive visibility rules."""
    result = []
    for raw in rows:
        if guardian_review(raw) or (thread_archived(raw) and not include_archived):
            continue
        row = normalize_thread({**raw, "archived": False})
        if row is not None:
            row["archived"] = thread_archived(raw)
            result.append(row)
    return result


def normalize_rpc_page(result, *, include_archived=False):
    """Normalize one native ``thread/list`` response while retaining cursors."""
    if not isinstance(result, dict):
        result = {}
    rows = filter_rows(result.get("data") or [], include_archived=include_archived)
    return {"threads": rows, "nextCursor": result.get("nextCursor"),
            "backwardsCursor": result.get("backwardsCursor")}


def _readonly(path):
    path = Path(path).expanduser().resolve()
    uri_path = quote(os.fspath(path), safe="/")
    connection = sqlite3.connect(f"file:{uri_path}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    return connection


def _columns(connection, table):
    return {row[1] for row in connection.execute(f"PRAGMA table_info({table})")}


def _cursor_offset(cursor):
    if cursor is None or cursor == "":
        return 0
    try:
        value = int(str(cursor).removeprefix("offset:"))
        if value < 0:
            raise ValueError
        return value
    except (TypeError, ValueError):
        raise CatalogError("invalid catalog cursor")


def _recorded_folder(cwd):
    """Normalize a recorded path lexically without following symlinks."""
    expanded = os.path.expanduser(os.fspath(cwd))
    return os.path.normpath(expanded)


def sqlite_threads(db_path, *, limit=100, cursor=None, cwd=None, project=None,
                   query=None, thread_id=None, include_archived=False):
    """Page every local metadata row; no implicit newest-N cutoff."""
    limit = max(1, min(int(limit), 1000))
    offset = _cursor_offset(cursor)
    connection = _readonly(db_path)
    try:
        cols = _columns(connection, "threads")
        selected = [name for name in (
            "id", "created_at", "updated_at", "created_at_ms", "updated_at_ms",
            "source", "thread_source", "archived", "cwd", "title", "name",
            "preview", "first_user_message", "project_id", "model", "git_branch",
            "recency_at_ms", "rollout_path") if name in cols]
        if "id" not in selected:
            return {"threads": [], "nextCursor": None}
        sql = "SELECT " + ", ".join(selected) + " FROM threads WHERE 1=1"
        values = []
        if thread_id:
            sql += " AND id = ?"
            values.append(thread_id)
        if "archived" in cols and not include_archived:
            sql += " AND COALESCE(archived, 0) = 0"
        if cwd is not None:
            normalized_cwd = _recorded_folder(cwd)
            sql += " AND cwd = ?"
            values.append(normalized_cwd)
        if project is not None and "project_id" in cols:
            sql += " AND project_id = ?"
            values.append(project)
        if query:
            available = [name for name in ("name", "title", "preview", "first_user_message") if name in cols]
            if available:
                sql += " AND (" + " OR ".join(f"COALESCE({name}, '') LIKE ?" for name in available) + ")"
                values.extend(["%" + query + "%"] * len(available))
        ordering = []
        recency_terms = []
        if "recency_at_ms" in cols:
            recency_terms.append("NULLIF(recency_at_ms, 0)")
        if "updated_at_ms" in cols:
            recency_terms.append("NULLIF(updated_at_ms, 0)")
        if "updated_at" in cols:
            recency_terms.append("updated_at * 1000")
        if recency_terms:
            ordering.append("COALESCE(" + ", ".join(recency_terms) + ") DESC")
        ordering.append("id ASC")
        sql += " ORDER BY " + ", ".join(ordering) + " LIMIT ? OFFSET ?"
        values.extend((limit + 1, offset))
        records = [dict(row) for row in connection.execute(sql, values)]
        has_more = len(records) > limit
        rows = filter_rows(records[:limit], include_archived=include_archived)
        return {"threads": rows,
                "nextCursor": f"offset:{offset + limit}" if has_more else None}
    finally:
        connection.close()


def sqlite_recent_threads(db_path, *, limit=100, cursor=None, cwd=None,
                          include_archived=False):
    """Return an activity-ordered, fast page of local thread metadata.

    The offset is into raw metadata rows. Guardian rows are skipped while
    filling a visible page, so they never cause short pages or pagination gaps.
    This deliberately performs no app-server, process, TTY, or owner probes.
    """
    limit = max(1, min(int(limit), 100))
    raw_offset = _cursor_offset(cursor)
    connection = _readonly(db_path)
    try:
        cols = _columns(connection, "threads")
        selected = [name for name in (
            "id", "created_at", "updated_at", "created_at_ms", "updated_at_ms",
            "recency_at_ms", "source", "thread_source", "archived", "cwd",
            "title", "name", "preview", "first_user_message", "project_id",
            "model", "git_branch") if name in cols]
        if "id" not in selected:
            return {"threads": [], "nextCursor": None}
        if cwd is not None and "cwd" not in cols:
            return {"threads": [], "nextCursor": None}
        terms = []
        if "recency_at_ms" in cols:
            terms.append("NULLIF(recency_at_ms, 0)")
        if "updated_at_ms" in cols:
            terms.append("NULLIF(updated_at_ms, 0)")
        if "updated_at" in cols:
            terms.append("NULLIF(updated_at, 0) * 1000")
        ordering = "COALESCE(" + ", ".join(terms + ["0"]) + ") DESC"
        ordering += ", id ASC"

        where = []
        values = []
        if not include_archived and "archived" in cols:
            where.append("COALESCE(archived, 0) = 0")
        if cwd is not None:
            where.append("cwd = ?")
            values.append(_recorded_folder(cwd))
        clause = " WHERE " + " AND ".join(where) if where else ""
        projection = ", ".join(selected)
        # Fetch metadata in modest chunks. The usual path reads only one chunk;
        # if guardian rows are interleaved, continue until a complete visible
        # page and one lookahead row establish the next cursor.
        page = []
        visible_positions = []
        fetched = 0
        chunk_size = max(100, limit + 1)
        while len(page) <= limit:
            rows = [dict(row) for row in connection.execute(
                f"SELECT {projection} FROM threads{clause} ORDER BY {ordering} LIMIT ? OFFSET ?",
                (*values, chunk_size, raw_offset + fetched))]
            if not rows:
                break
            fetched += len(rows)
            for index, row in enumerate(rows):
                if guardian_review(row):
                    continue
                if not include_archived and thread_archived(row):
                    continue
                page.append(row)
                visible_positions.append(fetched - len(rows) + index)
                if len(page) > limit:
                    break
            if len(page) > limit or len(rows) < chunk_size:
                break
        visible = []
        for raw in page[:limit]:
            row = normalize_thread({**raw, "archived": False})
            if row is not None:
                row["archived"] = thread_archived(raw)
                visible.append(row)
        next_cursor = (f"offset:{raw_offset + visible_positions[limit - 1] + 1}"
                       if len(page) > limit else None)
        return {"threads": visible, "nextCursor": next_cursor}
    finally:
        connection.close()


def sqlite_thread_record(db_path, thread_id):
    """Return unnormalized metadata for an exact preview/visibility check."""
    connection = _readonly(db_path)
    try:
        columns = _columns(connection, "threads")
        if "id" not in columns:
            return None
        row = connection.execute("SELECT * FROM threads WHERE id = ?", (thread_id,)).fetchone()
        return dict(row) if row is not None else None
    finally:
        connection.close()


def sqlite_latest_visible_turn(history_path, thread_id):
    """Return the latest user prompt and its subsequent visible answer.

    Tool calls, reasoning items, and prior-turn answers are never returned.
    """
    connection = _readonly(history_path)
    try:
        cols = _columns(connection, "thread_items")
        required = {"thread_id", "turn_id", "item_type", "item_json"}
        if not required.issubset(cols):
            return None
        created = "created_at_ms" if "created_at_ms" in cols else "rowid"
        ordinal = "rollout_ordinal" if "rollout_ordinal" in cols else "rowid"
        latest_user = None
        for raw in connection.execute(f"""
            SELECT turn_id, item_json, {ordinal} AS item_ordinal
              FROM thread_items
             WHERE thread_id = ? AND item_type = 'userMessage'
             ORDER BY {created} DESC, {ordinal} DESC LIMIT 200
        """, (thread_id,)):
            visible = _visible_item("userMessage", raw["item_json"])
            if visible:
                latest_user = (raw["turn_id"], raw["item_ordinal"], raw["item_json"])
                break
        if latest_user is None:
            return None
        turn_id, prompt_ordinal, prompt_json = latest_user
        candidates = []
        for raw in connection.execute(f"""
            SELECT item_json, {ordinal} AS item_ordinal
              FROM thread_items
             WHERE thread_id = ? AND turn_id = ? AND item_type = 'agentMessage'
               AND {ordinal} > ?
             ORDER BY {created} ASC, {ordinal} ASC LIMIT 1000
        """, (thread_id, turn_id, prompt_ordinal)):
            try:
                item = json.loads(raw["item_json"])
            except (TypeError, ValueError):
                continue
            text = item.get("text")
            if isinstance(text, str) and text.strip():
                candidates.append((item, text.strip()))
        answer = next((text for item, text in reversed(candidates)
                       if item.get("phase") == "final"), None)
        if answer is None and candidates:
            answer = candidates[-1][1]
        try:
            prompt = json.loads(prompt_json)
        except (TypeError, ValueError):
            return None
        # Keep the preview light even for unusually large source items.
        if answer is not None and len(answer) > 8000:
            answer = answer[:8000] + "…"
        for content in prompt.get("content", []):
            if (isinstance(content, dict) and content.get("type") == "text"
                    and isinstance(content.get("text"), str)
                    and len(content["text"]) > 4000):
                content["text"] = content["text"][:4000] + "…"
        items = [prompt]
        if answer is not None:
            items.append({"type": "agentMessage", "text": answer, "phase": "final"})
        return {"id": turn_id, "items": items}
    finally:
        connection.close()


def _visible_item(item_type, item_json):
    try:
        item = json.loads(item_json)
    except (TypeError, ValueError):
        return None
    if item_type in ("agentMessage", "plan"):
        text = item.get("text")
        return ("codex", text) if isinstance(text, str) and text.strip() else None
    if item_type != "userMessage":
        return None
    parts = [block["text"] for block in item.get("content", [])
             if isinstance(block, dict) and block.get("type") == "text"
             and isinstance(block.get("text"), str)]
    text = "\n".join(parts).strip()
    return ("me", text) if text else None


def _snippet(text, terms, before=60, after=140):
    lower = text.lower()
    positions = [lower.find(term) for term in terms]
    positions = [position for position in positions if position >= 0]
    at = min(positions) if positions else 0
    start, end = max(0, at - before), min(len(text), at + after)
    value = " ".join(text[start:end].split())
    return ("…" if start else "") + value + ("…" if end < len(text) else "")


def search_history(db_path, history_path, *, query, cwd, limit=50,
                   cursor=None, include_archived=False):
    """Search user prompts and assistant answers inside one exact folder.

    Searches all dates. Cursor pages matching chats after sorting by recency.
    """
    if cwd is None:
        raise CatalogError("a selected folder is required for history search")
    folder = _recorded_folder(cwd)
    terms = [term for term in str(query or "").lower().split() if term]
    if not terms:
        return {"threads": [], "nextCursor": None, "scanned": 0}
    offset = _cursor_offset(cursor)
    state = _readonly(db_path)
    history = _readonly(history_path)
    try:
        cols = _columns(state, "threads")
        select = [name for name in ("id", "rollout_path", "cwd", "title", "name",
                                    "preview", "git_branch", "updated_at", "updated_at_ms",
                                    "recency_at_ms", "source", "thread_source", "archived")
                  if name in cols]
        if not {"id", "cwd"}.issubset(select):
            return {"threads": [], "nextCursor": None, "scanned": 0}
        sql = "SELECT " + ", ".join(select) + " FROM threads WHERE cwd = ?"
        params = [folder]
        if "archived" in cols and not include_archived:
            sql += " AND COALESCE(archived, 0) = 0"
        metadata = {}
        for raw in state.execute(sql, params):
            row = dict(raw)
            if guardian_review(row):
                continue
            metadata[row["id"]] = row
        if not metadata:
            return {"threads": [], "nextCursor": None, "scanned": 0}
        item_cols = _columns(history, "thread_items")
        if not {"thread_id", "item_type", "item_json"}.issubset(item_cols):
            return {"threads": [], "nextCursor": None, "scanned": 0}
        created_col = "created_at_ms" if "created_at_ms" in item_cols else "rowid"
        ordinal = "rollout_ordinal" if "rollout_ordinal" in item_cols else "rowid"
        found = {}
        # Keep each IN query below SQLite's conservative 999-variable limit.
        # Every batch is independently ordered newest-first, so the first match
        # seen for a chat still supplies its newest matching role/snippet.
        thread_ids = list(metadata)
        for index in range(0, len(thread_ids), 400):
            batch = thread_ids[index:index + 400]
            placeholders = ",".join("?" for _ in batch)
            items = history.execute(f"""
                SELECT thread_id, item_type, item_json FROM thread_items
                 WHERE thread_id IN ({placeholders})
                   AND item_type IN ('userMessage', 'agentMessage', 'plan')
                 ORDER BY {created_col} DESC, {ordinal} DESC
            """, tuple(batch))
            for raw in items:
                visible = _visible_item(raw["item_type"], raw["item_json"])
                if not visible:
                    continue
                role, text = visible
                lower = text.lower()
                if not all(term in lower for term in terms):
                    continue
                thread_id = raw["thread_id"]
                meta = metadata[thread_id]
                value = found.get(thread_id)
                if value is None:
                    updated_ms = meta.get("updated_at_ms") or meta.get("recency_at_ms")
                    updated = (updated_ms / 1000 if updated_ms else meta.get("updated_at") or 0)
                    cwd_path = meta.get("cwd") or ""
                    value = {
                        "session": thread_id, "path": meta.get("rollout_path") or "",
                        "mtime": updated, "cwd": cwd_path,
                        "folder": Path(cwd_path).name or cwd_path,
                        "branch": meta.get("git_branch") or "",
                        "title": meta.get("name") or meta.get("title") or meta.get("preview") or "",
                        "hits": 0, "role": role, "snippet": _snippet(text, terms),
                    }
                    found[thread_id] = value
                value["hits"] += 1
        ordered = sorted(found.values(), key=lambda item: (-item["mtime"], item["session"]))
        page = ordered[offset:offset + max(1, min(int(limit), 1000))]
        next_offset = offset + len(page)
        return {"threads": page,
                "nextCursor": f"offset:{next_offset}" if next_offset < len(ordered) else None,
                "scanned": len(metadata)}
    finally:
        history.close()
        state.close()


def guard_history_preview(thread_id, raw_thread):
    """Reject guardian review metadata before a caller exposes history items."""
    if guardian_review(raw_thread):
        raise CatalogError(f"history preview is unavailable for guardian review thread {thread_id}")

