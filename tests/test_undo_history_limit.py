#!/usr/bin/env python3
"""Guards for user-adjustable undo history limit.
Default 10 (Leon's request; was hard 50), adjustable in Settings 1...50,
persisted under folderium.undoHistoryLimit, and actually enforced at
record time."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DUAL = (ROOT / "Folderium App" / "Folderium" / "DualPaneView.swift").read_text()
APP = (ROOT / "Folderium App" / "Folderium" / "FolderiumApp.swift").read_text()


class UndoHistoryLimitTests(unittest.TestCase):
    def test_key_and_default_exist(self):
        self.assertIn('static let undoHistoryLimitKey = "folderium.undoHistoryLimit"', DUAL)
        self.assertIn("static let defaultUndoHistoryLimit = 10", DUAL)

    def test_record_reads_user_limit(self):
        self.assertIn("forKey: Self.undoHistoryLimitKey", DUAL)
        self.assertIn("Self.defaultUndoHistoryLimit", DUAL)
        self.assertNotIn("undoStack.count > 50", DUAL, "hard 50 cap still present")

    def test_settings_ui_exists(self):
        self.assertIn("@AppStorage(DualPaneView.undoHistoryLimitKey)", APP)
        self.assertIn("Undo 歷史上限", APP)
        self.assertIn("in: 1...50", APP)

    def test_limit_enforced_on_append(self):
        self.assertIn("undoStack.removeFirst(undoStack.count - limit)", DUAL)


if __name__ == "__main__":
    unittest.main()
