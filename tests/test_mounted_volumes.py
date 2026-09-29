"""Source-level regression guard for the UI-thread mounted-volume stall.

The sampled main thread was inside FileManager.mountedVolumeURLs from
DualPaneView.quickAccessSidebar. Keep that blocking filesystem operation out
of SwiftUI view evaluation; the CLT-built app has no XCTest target.
"""
from pathlib import Path
import re
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "Folderium App" / "Folderium" / "DualPaneView.swift")


class MountedVolumesMainThreadTests(unittest.TestCase):
    def test_sidebar_renders_cached_volumes_not_a_synchronous_enumeration(self):
        source = SOURCE.read_text()
        self.assertTrue("@State private var mountedVolumes: [QuickLocation] = []" in source,
                        "mounted volumes must be cached in view state")
        self.assertNotRegex(source, r"private var mountedVolumes:\s*\[QuickLocation\]\s*\{")
        self.assertEqual(source.count("mountedVolumeURLs("), 1)
        loader = re.search(r"(?:nonisolated )?private static func loadMountedVolumes\([^)]*\)[^{]*\{(.*?)\n    \}", source, re.S)
        assert loader is not None
        self.assertIn("mountedVolumeURLs(", loader.group(1))
        refresher = re.search(r"private func refreshMountedVolumes\([^)]*\)[^{]*\{(.*?)\n    \}", source, re.S)
        assert refresher is not None
        self.assertIn("Task.detached", refresher.group(1))
        self.assertRegex(refresher.group(1), r"mountedVolumes\s*=\s*volumes")


if __name__ == "__main__":
    unittest.main()
