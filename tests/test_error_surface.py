#!/usr/bin/env python3
"""Source guards for the P1 user-visible error surface.
Every user file action that fails must surface through
FileOperationErrorCenter (toast), not print-only."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC_DIR = ROOT / "Folderium App" / "Folderium"


def all_swift() -> str:
    parts = [p.read_text() for p in sorted(SRC_DIR.rglob("*.swift"))]
    return "\n".join(parts)


class ErrorSurfaceTests(unittest.TestCase):
    def test_error_center_component_exists(self):
        src = (SRC_DIR / "Managers" / "ErrorCenter.swift").read_text()
        self.assertIn("final class FileOperationErrorCenter", src)
        self.assertIn("func report(", src)
        self.assertIn("struct FileOperationErrorToastOverlay", src)
        # Bounded queue: at most a few toasts visible at once.
        self.assertIn("maxVisible", src)

    def test_content_view_mounts_toast_overlay(self):
        src = (SRC_DIR / "ContentView.swift").read_text()
        self.assertIn("FileOperationErrorToastOverlay()", src)

    def test_user_actions_report_failures(self):
        src = all_swift()
        # At least the wired action paths: paste, drop, delete, compress(x2),
        # trash, create folder(x2), create file, open-with, file info,
        # folder size, undo, redo.
        self.assertGreaterEqual(
            src.count("FileOperationErrorCenter.shared.report"),
            12,
            f"only {src.count('FileOperationErrorCenter.shared.report')} report sites",
        )

    def test_report_is_mainactor(self):
        src = (SRC_DIR / "Managers" / "ErrorCenter.swift").read_text()
        self.assertIn("@MainActor", src)


if __name__ == "__main__":
    unittest.main()
