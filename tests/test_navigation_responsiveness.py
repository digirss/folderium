"""Regression gates for filesystem work reachable from navigation/render.

Source guards complement the compiled Swift slow-filesystem harness. They do
not claim that a live SMB outage or GUI beachball has been reproduced.
"""
from pathlib import Path
import re
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'Folderium App/Folderium/DualPaneView.swift'


def body(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    pos = opening + 1
    while depth:
        depth += (source[pos] == '{') - (source[pos] == '}')
        pos += 1
    return source[opening + 1:pos - 1]


class NavigationResponsivenessTests(unittest.TestCase):
    def test_directory_load_clears_invisible_selection_before_async_work(self):
        source = SOURCE.read_text()
        load = body(source, 'private func loadFiles()')
        before_io = load.split('Task.detached', 1)[0]
        self.assertIn('selection = []', before_io)
        self.assertIn('keyboardSelectionAnchor = nil', before_io)
        self.assertIn('keyboardSelectionFocus = nil', before_io)

    def test_cloud_named_folder_double_click_does_not_do_filesystem_io_on_main(self):
        source = SOURCE.read_text()
        handler = body(source, 'private func handleDoubleClick(_ file: FileItem)')
        self.assertIn('if file.isSymbolicLink', handler)
        self.assertIn('Task.detached', handler)
        self.assertIn('destinationOfSymbolicLink', handler)
        self.assertNotIn('FileManager.default', handler.split('Task.detached', 1)[0])

    def test_toolbar_permission_is_cached_not_io_during_render(self):
        source = SOURCE.read_text()
        self.assertIn('@State private var writableFolderPath: String?', source)
        computed = body(source, 'private var canCreateFolderInActivePane: Bool')
        self.assertNotIn('FileManager', computed)
        self.assertIn('writableFolderPath == activePanePath.path', computed)
        task = body(source, '.task(id: activePanePath)')
        self.assertIn('Task.detached', task)
        self.assertIn('isWritableFile', task)
        self.assertIn('!Task.isCancelled', task)


    def test_path_entry_and_breadcrumbs_do_not_probe_filesystem(self):
        source = SOURCE.read_text()
        commit = body(source, 'private func commitPathInput()')
        self.assertNotIn('FileManager', commit)
        self.assertIn('URL(fileURLWithPath: expandedPath, isDirectory: true)', commit)
        breadcrumb = body(source, 'private func navigateToPath(at')
        self.assertIn('appendingPathComponent(pathComponents[i], isDirectory: true)', breadcrumb)

    def test_pins_do_not_probe_or_delete_temporarily_offline_folders(self):
        source = SOURCE.read_text()
        sanitize = body(source, 'private func sanitizePinnedPaths(_ paths:')
        self.assertNotIn('FileManager', sanitize)
        self.assertIn('trimmed.hasPrefix("/")', sanitize)
        pinned = body(source, 'private var pinnedLocations:')
        self.assertIn('URL(fileURLWithPath: path, isDirectory: true)', pinned)

    def test_bookmark_restore_is_not_run_in_on_appear(self):
        source = SOURCE.read_text()
        on_appear = source[source.index('        .onAppear {\n            refreshMountedVolumes()'):source.index('        .onDisappear {')]
        self.assertNotIn('SandboxAccessManager.restoreBookmark', on_appear)
        restore = body(source, 'private func restoreStartupFolders()')
        self.assertIn('Task.detached', restore)
        self.assertIn('SandboxAccessManager.restoreBookmark', restore)
        self.assertIn('!Task.isCancelled', restore)
        self.assertIn('leftPath == originalLeft', restore)


if __name__ == '__main__':
    unittest.main()
