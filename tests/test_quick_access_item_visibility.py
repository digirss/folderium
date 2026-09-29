"""UI wiring guard; the visibility model is exercised by the Swift smoke test.

The CLT app has no XCTest target; real menu interaction and persistence
still require GUI acceptance on a built bundle.
"""
from pathlib import Path
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "Folderium App" / "Folderium" / "DualPaneView.swift")
BUILD_SCRIPT = (Path(__file__).resolve().parents[1] / "Folderium App" / "scripts" / "build_app_clt.sh")


class QuickAccessItemVisibilityTests(unittest.TestCase):
    def assert_source_has(self, source: str, snippet: str):
        self.assertTrue(snippet in source, f"missing source contract: {snippet!r}")

    def test_default_shortcuts_use_versioned_visibility_model(self):
        source = SOURCE.read_text()
        self.assert_source_has(source, '@AppStorage("folderium.quickAccessHiddenItems") private var hiddenQuickAccessItemsRaw: String = ""')
        self.assert_source_has(source, 'QuickAccessVisibility(storedValue: hiddenQuickAccessItemsRaw)')
        self.assert_source_has(source, 'ForEach(visibleQuickLocations) { location in')
        self.assert_source_has(source, 'QuickLocation(name: "Pictures"')

    def test_menu_can_hide_and_restore_a_shortcut_without_losing_other_choices(self):
        source = SOURCE.read_text()
        self.assert_source_has(source, 'Menu {\n                        ForEach(quickLocations)')
        self.assert_source_has(source, '.frame(maxWidth: .infinity, alignment: .leading)\n            .padding(.horizontal, 12)')
        self.assert_source_has(source, '.menuIndicator(.hidden)')
        self.assert_source_has(source, 'Toggle(location.name, isOn: visibilityBinding(.shortcut, location.name))')
        self.assert_source_has(source, 'visibility.setVisible(category, identifier, visible: isVisible)')
        self.assert_source_has(source, 'hiddenQuickAccessItemsRaw = visibility.storedValue')
        self.assert_source_has(source, 'Button("Show All Items") {\n                            hiddenQuickAccessItemsRaw = ""')

    def test_recent_items_and_section_can_be_hidden_independently(self):
        source = SOURCE.read_text()
        self.assert_source_has(source, 'Menu("Recent") {')
        self.assert_source_has(source, 'Toggle("Show Recent", isOn: visibilityBinding(.section, "Recent"))')
        self.assert_source_has(source, 'Toggle(location.name, isOn: visibilityBinding(.recent, location.url.path))')
        self.assert_source_has(source, 'let visibleRecentLocations = quickAccessVisible(.section, "Recent")')
        self.assert_source_has(source, 'ForEach(visibleRecentLocations) { location in')
        self.assert_source_has(source, 'if !visibleRecentLocations.isEmpty {')

    def test_pinned_items_are_hidden_without_unpinning(self):
        source = SOURCE.read_text()
        self.assert_source_has(source, 'Menu("Pinned") {')
        self.assert_source_has(source, 'Toggle("Show Pinned", isOn: visibilityBinding(.section, "Pinned"))')
        self.assert_source_has(source, 'Toggle(location.name, isOn: visibilityBinding(.pinned, location.url.path))')
        self.assert_source_has(source, 'let visiblePinnedLocations = quickAccessVisible(.section, "Pinned")')
        self.assert_source_has(source, 'ForEach(visiblePinnedLocations, id: \\.url.path) { location in')
        self.assert_source_has(source, 'unpinLocation(location.url)')

    def test_each_drive_can_be_hidden_without_unmounting(self):
        source = SOURCE.read_text()
        self.assert_source_has(source, 'Menu("Drives") {')
        self.assert_source_has(source, 'Toggle("Show Drives", isOn: visibilityBinding(.section, "Drives"))')
        self.assert_source_has(source, 'Toggle(location.name, isOn: visibilityBinding(.drive, location.url.path))')
        self.assert_source_has(source, 'let visibleMountedVolumes = quickAccessVisible(.section, "Drives")')
        self.assert_source_has(source, 'ForEach(visibleMountedVolumes) { location in')
        self.assert_source_has(source, 'unmountVolume(location.url)')

    def test_bottom_actions_can_be_hidden_without_removing_recovery_menu(self):
        source = SOURCE.read_text()
        self.assert_source_has(source, 'Menu("Actions") {')
        self.assert_source_has(source, 'Toggle("Pin Active Folder", isOn: visibilityBinding(.action, "Pin Active Folder"))')
        self.assert_source_has(source, 'Toggle("Choose Folder...", isOn: visibilityBinding(.action, "Choose Folder"))')
        self.assert_source_has(source, 'if quickAccessVisible(.action, "Pin Active Folder") {')
        self.assert_source_has(source, 'if quickAccessVisible(.action, "Choose Folder") {')
        self.assert_source_has(source, '.accessibilityLabel("Choose Quick Access items")')

    def test_hidden_shortcuts_leave_no_orphan_separator(self):
        source = SOURCE.read_text()
        self.assert_source_has(source, 'let visibleQuickLocations = quickLocations.filter { quickAccessVisible(.shortcut, $0.name) }')
        self.assert_source_has(source, 'if !visibleQuickLocations.isEmpty && hasFollowingQuickAccessContent {\n                        Divider().padding(.vertical, 6)')

    def test_delivered_bundle_has_a_new_version(self):
        source = BUILD_SCRIPT.read_text()
        import re
        version = re.search(r'^VERSION="(\d+)\.(\d+)\.(\d+)"$', source, re.M)
        assert version is not None
        self.assertGreaterEqual(tuple(map(int, version.groups())), (0, 1, 2))
        build = re.search(r'<key>CFBundleVersion</key>\s*<string>(\d+)</string>', source)
        assert build is not None
        self.assertGreaterEqual(int(build.group(1)), 3)


if __name__ == "__main__":
    unittest.main()
