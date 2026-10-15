#!/usr/bin/env python3
import contextlib
import io
import os
import sqlite3
import tempfile
import unittest
from unittest import mock

import corpus_report


class CorpusReportSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        corpus_report.CORPUS = self.temp.name
        corpus_report.CORPUS_DB = os.path.join(self.temp.name, "corpus.db")
        corpus_report.BASELINE = os.path.join(self.temp.name, "baseline.json")
        corpus_report.ENV_FILE = os.path.join(self.temp.name, "report.env")
        db = sqlite3.connect(corpus_report.CORPUS_DB)
        db.executescript("""
            CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE samples (seconds REAL, num_words INTEGER, bytes INTEGER,
                harvested_at TEXT, edited_text TEXT, source TEXT, language TEXT, ts TEXT);
            CREATE TABLE runs (error TEXT, started_at TEXT);
        """)
        db.commit()
        db.close()

    def test_default_invocation_previews_even_if_mail_credentials_exist(self):
        with mock.patch.object(corpus_report.sys, "argv", ["corpus_report.py"]), \
             mock.patch.dict(os.environ, {
                 "AGENTMAIL_API_KEY": "test-key",
                 "CORPUS_REPORT_TO": "configured@example.invalid",
                 "CORPUS_REPORT_INBOX": "configured-inbox",
             }), mock.patch.object(corpus_report, "send", side_effect=AssertionError("must not send")):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(corpus_report.main(), 0)
        self.assertIn("VOICE CORPUS", output.getvalue())

    def test_send_requires_explicit_recipient_and_inbox_without_network(self):
        with mock.patch.dict(os.environ, {"AGENTMAIL_API_KEY": "test-key"}, clear=True), \
             mock.patch.object(corpus_report.urllib.request, "urlopen") as urlopen:
            with self.assertRaisesRegex(RuntimeError, "CORPUS_REPORT_TO and CORPUS_REPORT_INBOX"):
                corpus_report.send("subject", "body")
            urlopen.assert_not_called()


if __name__ == "__main__":
    unittest.main()
