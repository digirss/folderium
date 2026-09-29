#!/usr/bin/env python3
"""Source-level guards: selection-driven re-renders must not do pasteboard XPC
reads or repeated width writes. Symptom (2026-09-30): clicking a row froze the
app for seconds — every visible row eagerly evaluated canPasteFromClipboard()
(pasteboard.readObjects = XPC round trip) during ForEach body construction,
and the toolbar re-read the clipboard on every DualPaneView body render."""
import re
import unittest
from pathlib import Path

APP = Path(__file__).resolve().parents[1] / "Folderium App" / "Folderium" / "DualPaneView.swift"
SOURCE = APP.read_text()


class SelectionRenderResponsivenessTests(unittest.TestCase):
    def test_rows_do_not_eagerly_probe_clipboard(self):
        """The per-row ForEach must not CALL canPasteFromClipboard() while
        constructing row views (the call itself reads the pasteboard over XPC);
        rows receive a closure evaluated only when a menu opens."""
        for hit in ["canPasteFromClipboard: canPasteFromClipboard(),"]:
            self.assertNotIn(
                hit, SOURCE,
                "per-row eager clipboard probe still present in row construction")

    def test_toolbar_does_not_read_clipboard_in_body(self):
        """DualPaneView body must not call hasFilesInClipboard() (XPC read)
        inline; it must use a cached flag."""
        self.assertNotIn(
            ".disabled(!hasFilesInClipboard())",
            SOURCE,
            "toolbar still reads the pasteboard synchronously during body render")

    def test_clipboard_flag_refreshed_via_changecount_off_render(self):
        """The cached clipboard flag must be refreshed from
        NSPasteboard.general.changeCount (cheap local int) with the expensive
        readObjects kept off the render path."""
        self.assertIn("changeCount", SOURCE,
                      "no changeCount-based clipboard refresh found")
        self.assertIn("clipboardHasFiles", SOURCE,
                      "no cached clipboardHasFiles state found")

    def test_table_width_guarded_against_frame_repeats(self):
        """GeometryReader width writes must be guarded so identical/epsilon
        widths do not trigger onChange multiple times per frame."""
        m = re.search(r"onChange\(of: geometry\.size\.width\).*?\n(.*?)\n\s*\}",
                      SOURCE, re.S)
        self.assertIsNotNone(m, "geometry width onChange not found")
        body = m.group(1)
        self.assertIn("abs(", body,
                      "width write lacks epsilon guard against per-frame repeats")


if __name__ == "__main__":
    unittest.main()
