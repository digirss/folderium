#!/usr/bin/env python3
"""Source guards: the three remaining main-thread synchronous file I/O
hot spots found in the 2026-09-30 re-audit.
- performSelectedDelete: called straight from the delete-confirmation alert
  button on the main actor; trash/remove must run detached.
- undoLastOperation / redoLastOperation: ran `Task { ... }` which inherits
  the MainActor context, so every moveItem in the loop blocked the UI.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = (ROOT / "Folderium App" / "Folderium" / "DualPaneView.swift").read_text()


def method_body(src: str, signature: str) -> str:
    """Return the body of the method whose source contains `signature`."""
    idx = src.find(signature)
    assert idx != -1, f"signature not found: {signature}"
    brace = src.find("{", idx)
    depth, j = 1, brace + 1
    while depth and j < len(src):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
        j += 1
    return src[brace:j]


class PostConfirmationActionResponsivenessTests(unittest.TestCase):
    def test_perform_selected_delete_runs_io_detached(self):
        body = method_body(SRC, "private func performSelectedDelete() {")
        self.assertIn("Task.detached", body, "delete I/O still runs on the main actor")

    def test_undo_runs_io_detached(self):
        body = method_body(SRC, "private func undoLastOperation() {")
        self.assertIn("Task.detached", body, "undo I/O still runs on the main actor")

    def test_redo_runs_io_detached(self):
        body = method_body(SRC, "private func redoLastOperation() {")
        self.assertIn("Task.detached", body, "redo I/O still runs on the main actor")


if __name__ == "__main__":
    unittest.main()
