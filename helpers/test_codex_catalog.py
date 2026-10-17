import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

import codex_catalog


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.state = self.root / "state_5.sqlite"
        self.history = self.root / "thread_history_1.sqlite"
        db = sqlite3.connect(self.state)
        db.executescript("""
            CREATE TABLE threads (
                id TEXT PRIMARY KEY, rollout_path TEXT, created_at INTEGER,
                updated_at INTEGER, created_at_ms INTEGER, updated_at_ms INTEGER,
                source TEXT, thread_source TEXT, cwd TEXT, title TEXT, name TEXT,
                preview TEXT, first_user_message TEXT, project_id TEXT, model TEXT,
                git_branch TEXT, archived INTEGER, recency_at_ms INTEGER
            );
        """)
        db.commit()
        db.close()
        db = sqlite3.connect(self.history)
        db.executescript("""
            CREATE TABLE thread_items (
                thread_id TEXT, turn_id TEXT, item_id TEXT, rollout_ordinal INTEGER,
                created_at_ms INTEGER, item_json TEXT, item_type TEXT
            );
        """)
        db.commit()
        db.close()

    def tearDown(self):
        self.temp.cleanup()

    def add_thread(self, thread_id, *, cwd="/work/alpha", title=None,
                   updated=1000, archived=0, source="cli", thread_source=None):
        db = sqlite3.connect(self.state)
        db.execute("""INSERT INTO threads VALUES
            (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                   (thread_id, f"/rollouts/{thread_id}.jsonl", updated // 1000,
                    updated // 1000, updated, updated, source,
                    thread_source, cwd, title or thread_id, title or thread_id,
                    "", "", None, "test", "main", archived, updated))
        db.commit()
        db.close()

    def add_item(self, thread_id, text, role="user", ordinal=1, created=1000):
        kind = "userMessage" if role == "user" else "agentMessage"
        if role == "user":
            item = {"type": kind, "content": [{"type": "text", "text": text}]}
        else:
            item = {"type": kind, "text": text}
        db = sqlite3.connect(self.history)
        db.execute("INSERT INTO thread_items VALUES (?, ?, ?, ?, ?, ?, ?)",
                   (thread_id, "turn", f"item-{ordinal}", ordinal, created,
                    json.dumps(item), kind))
        db.commit()
        db.close()

    def test_guardian_detection_is_exact_and_preserves_ordinary_agent_threads(self):
        cases = [
            ({"threadSource": "guardian_review"}, True),
            ({"thread_source": "guardian_review"}, True),
            ({"source": {"subAgent": {"other": "guardian"}}}, True),
            ({"source": {"subagent": {"other": "guardian"}}}, True),
            ({"threadSource": "agent_created_thread"}, False),
            ({"source": {"subAgent": {"other": "worker"}}}, False),
            ({"source": "cli", "threadSource": "user"}, False),
        ]
        for row, expected in cases:
            with self.subTest(row=row):
                self.assertEqual(codex_catalog.guardian_review(row), expected)
        self.assertIsNone(codex_catalog.normalize_thread(
            {"id": "guardian", "threadSource": "guardian_review"}))
        self.assertEqual(codex_catalog.normalize_thread(
            {"id": "agent", "threadSource": "agent_created_thread"})["id"], "agent")

    def test_native_page_filter_hides_guardian_and_archived_by_default(self):
        result = codex_catalog.normalize_rpc_page({"data": [
            {"id": "cli", "cwd": "/work/alpha", "source": "cli"},
            {"id": "guardian", "threadSource": "guardian_review"},
            {"id": "archived", "archived": True},
        ], "nextCursor": "next", "backwardsCursor": "prev"})
        self.assertEqual([row["id"] for row in result["threads"]], ["cli"])
        self.assertEqual(result["nextCursor"], "next")
        included = codex_catalog.filter_rows([
            {"id": "archived", "archived": 1},
            {"id": "guardian", "archived": 1, "thread_source": "guardian_review"},
        ], include_archived=True)
        self.assertEqual([(row["id"], row["archived"]) for row in included],
                         [("archived", True)])

    def test_offline_catalog_pages_beyond_newest_hundred_and_archive_toggle(self):
        for index in range(112):
            self.add_thread(f"thread-{index:03}", updated=index + 1000)
        self.add_thread("archived", updated=3000, archived=1)
        first = codex_catalog.sqlite_threads(self.state, limit=40)
        second = codex_catalog.sqlite_threads(self.state, limit=40,
                                              cursor=first["nextCursor"])
        third = codex_catalog.sqlite_threads(self.state, limit=40,
                                             cursor=second["nextCursor"])
        ids = [row["id"] for page in (first, second, third) for row in page["threads"]]
        self.assertEqual(len(ids), 112)
        self.assertEqual(len(set(ids)), 112)
        self.assertNotIn("archived", ids)
        archived = codex_catalog.sqlite_threads(self.state, limit=200,
                                                include_archived=True)
        self.assertIn("archived", [row["id"] for row in archived["threads"]])

    def test_recent_pages_sort_by_recency_and_fill_around_guardians(self):
        self.add_thread("old-update", updated=9_000)
        self.add_thread("recent-activity", updated=1_000)
        self.add_thread("guardian-a", updated=8_000, thread_source="guardian_review")
        self.add_thread("guardian-b", updated=7_000, thread_source="guardian_review")
        self.add_thread("middle", updated=6_000)
        self.add_thread("archived", updated=10_000, archived=1)
        db = sqlite3.connect(self.state)
        db.execute("UPDATE threads SET recency_at_ms = 12000 WHERE id = 'recent-activity'")
        db.execute("UPDATE threads SET recency_at_ms = 0 WHERE id = 'old-update'")
        db.execute("UPDATE threads SET source = ? WHERE id = 'guardian-a'",
                   (json.dumps({"subAgent": {"other": "guardian"}}),))
        db.commit()
        db.close()

        first = codex_catalog.sqlite_recent_threads(self.state, limit=2)
        second = codex_catalog.sqlite_recent_threads(
            self.state, limit=2, cursor=first["nextCursor"])
        self.assertEqual([row["id"] for row in first["threads"]],
                         ["recent-activity", "old-update"])
        self.assertEqual([row["id"] for row in second["threads"]], ["middle"])
        self.assertIsNone(second["nextCursor"])

    def test_recent_pages_keep_exact_folder_and_archived_filtering(self):
        self.add_thread("alpha-new", cwd="/work/alpha", updated=5000)
        self.add_thread("beta-new", cwd="/work/beta", updated=6000)
        self.add_thread("alpha-archived", cwd="/work/alpha", updated=7000, archived=1)
        normal = codex_catalog.sqlite_recent_threads(
            self.state, limit=10, cwd="/work/alpha")
        archived = codex_catalog.sqlite_recent_threads(
            self.state, limit=10, cwd="/work/alpha", include_archived=True)
        self.assertEqual([row["id"] for row in normal["threads"]], ["alpha-new"])
        self.assertEqual([row["id"] for row in archived["threads"]],
                         ["alpha-archived", "alpha-new"])

    def test_latest_preview_uses_latest_turn_and_omits_prior_answer(self):
        db = sqlite3.connect(self.history)
        thread = "preview-chat"
        rows = [
            (thread, "turn-1", "u1", 1, 1,
             {"type": "userMessage", "content": [{"type": "text", "text": "first prompt"}]},
             "userMessage"),
            (thread, "turn-1", "a1", 2, 2,
             {"type": "agentMessage", "text": "first answer", "phase": "final"},
             "agentMessage"),
            (thread, "turn-2", "u2", 3, 3,
             {"type": "userMessage", "content": [{"type": "text", "text": "latest prompt"}]},
             "userMessage"),
        ]
        db.executemany("INSERT INTO thread_items VALUES (?, ?, ?, ?, ?, ?, ?)", [
            (tid, turn, item, ordinal, created, json.dumps(payload), kind)
            for tid, turn, item, ordinal, created, payload, kind in rows
        ])
        db.commit()
        db.close()
        preview = codex_catalog.sqlite_latest_visible_turn(self.history, thread)
        self.assertEqual(preview["id"], "turn-2")
        self.assertIn("latest prompt", preview["items"][0]["content"][0]["text"])
        self.assertEqual(len(preview["items"]), 1)

    def test_folder_search_finds_old_prompts_and_answers_only_in_selected_cwd(self):
        old = "old-match"
        other = "other-folder"
        guardian = "guardian"
        ordinary_agent = "ordinary-agent"
        self.add_thread(old, updated=1, title="Old chat")
        self.add_thread(other, cwd="/work/beta", updated=99_000_000)
        self.add_thread(guardian, thread_source="guardian_review")
        self.add_thread(ordinary_agent, thread_source="agent_created_thread")
        self.add_item(old, "A rare blue comet appeared", role="user", created=1)
        self.add_item(old, "The rare blue comet is visible", role="assistant", ordinal=2, created=2)
        self.add_item(other, "A rare blue comet appeared", role="user")
        self.add_item(guardian, "A rare blue comet appeared", role="user")
        self.add_item(ordinary_agent, "A rare blue comet appeared", role="user")
        page = codex_catalog.search_history(
            self.state, self.history, query="rare comet", cwd="/work/alpha", limit=10)
        by_id = {row["session"]: row for row in page["threads"]}
        self.assertIn(old, by_id)
        self.assertIn(ordinary_agent, by_id)
        self.assertNotIn(guardian, by_id)
        self.assertEqual(by_id[old]["hits"], 2)
        self.assertEqual(by_id[old]["cwd"], "/work/alpha")
        self.assertIsNone(page["nextCursor"])
        self.assertEqual(codex_catalog.search_history(
            self.state, self.history, query="rare", cwd="/work/beta")["threads"][0]["session"], other)

    def test_history_preview_guard_refuses_guardian_metadata(self):
        with self.assertRaises(codex_catalog.CatalogError):
            codex_catalog.guard_history_preview(
                "g", {"threadSource": "guardian_review"})
        codex_catalog.guard_history_preview("u", {"threadSource": "agent_created_thread"})

    def test_minimal_offline_schema_pages_without_missing_recency_columns(self):
        minimal = self.root / "minimal.sqlite"
        db = sqlite3.connect(minimal)
        db.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, title TEXT)")
        db.executemany("INSERT INTO threads VALUES (?, ?, ?)", [
            (f"m-{index}", "/work/minimal", f"Chat {index}") for index in range(4)
        ])
        db.commit()
        db.close()
        first = codex_catalog.sqlite_threads(minimal, limit=2)
        second = codex_catalog.sqlite_threads(minimal, limit=2,
                                              cursor=first["nextCursor"])
        self.assertEqual(len(first["threads"]), 2)
        self.assertEqual(len(second["threads"]), 2)
        self.assertIsNone(second["nextCursor"])

    def test_database_filename_with_uri_special_characters_is_readable(self):
        special = self.root / "state?# snapshot.sqlite"
        db = sqlite3.connect(special)
        db.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, title TEXT)")
        db.execute("INSERT INTO threads VALUES ('special', '/work/special', 'Special')")
        db.commit()
        db.close()
        rows = codex_catalog.sqlite_threads(special)
        self.assertEqual([row["id"] for row in rows["threads"]], ["special"])

    def test_history_search_batches_more_than_sqlite_variable_limit(self):
        for index in range(1005):
            self.add_thread(f"many-{index:04}", cwd="/work/alpha", updated=index + 1000)
        self.add_item("many-1004", "marker from a large folder history")
        result = codex_catalog.search_history(
            self.state, self.history, query="large folder", cwd="/work/alpha")
        self.assertEqual([row["session"] for row in result["threads"]], ["many-1004"])
        self.assertEqual(result["scanned"], 1005)

    def test_folder_filter_preserves_recorded_symlink_path(self):
        real = self.root / "real-project"
        alias = self.root / "project-alias"
        real.mkdir()
        alias.symlink_to(real, target_is_directory=True)
        recorded = str(alias)
        self.add_thread("symlink-folder", cwd=recorded)
        self.add_item("symlink-folder", "find the linked folder")
        result = codex_catalog.search_history(
            self.state, self.history, query="linked folder", cwd=recorded)
        self.assertEqual([row["session"] for row in result["threads"]], ["symlink-folder"])
        self.assertEqual(result["threads"][0]["cwd"], recorded)


if __name__ == "__main__":
    unittest.main()
