"""Source-level guard for row selection handing keyboard focus to the file pane.

The CLT-only app has no XCTest target. This catches a missing focus handoff;
real Enter/inline-rename behavior still requires GUI acceptance.
"""
from pathlib import Path
import re
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "Folderium App" / "Folderium" / "DualPaneView.swift")


class RowKeyboardFocusTests(unittest.TestCase):
    def test_click_on_row_claims_focus_before_selection(self):
        source = SOURCE.read_text()
        row_view = source.split("final class MouseCaptureNSView: NSView {", 1)[1].split(
            "// MARK: - Sandbox Access", 1
        )[0]
        self.assertRegex(row_view, r"override\s+var\s+acceptsFirstResponder:\s*Bool\s*\{\s*true\s*\}")
        mouse_down = re.search(r"override func mouseDown\(with event: NSEvent\) \{(.*?)\n        \}", row_view, re.S)
        assert mouse_down is not None
        body = mouse_down.group(1)
        self.assertIn("window?.makeFirstResponder(self)", body)
        self.assertLess(body.index("window?.makeFirstResponder(self)"),
                        body.index("onMouseDown?(event)"))

    def test_text_editor_still_receives_unmodified_keys(self):
        source = SOURCE.read_text()
        monitor = source.split("private func startShortcutMonitor()", 1)[1].split(
            "private func stopShortcutMonitor()", 1
        )[0]
        self.assertIn("responder.isEditable", monitor)
        self.assertIn("if !event.modifierFlags.contains(.command) {\n                    return event", monitor)


if __name__ == "__main__":
    unittest.main()
