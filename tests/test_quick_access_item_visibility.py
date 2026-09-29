"""Source guard for user-configurable Quick Access default rows.

The CLT app has no XCTest target; real menu interaction and persistence
still require GUI acceptance on a built bundle.
"""
from pathlib import Path
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "Folderium App" / "Folderium" / "DualPaneView.swift")


class QuickAccessItemVisibilityTests(unittest.TestCase):
    def assert_source_has(self, source: str, snippet: str):
        self.assertTrue(snippet in source, f"missing source contract: {snippet!r}")

    def test_default_shortcuts_are_filtered_by_persisted_hidden_names(self):
        source = SOURCE.read_text()
        self.assert_source_has(source, '@AppStorage("folderium.quickAccessHiddenItems") private var hiddenQuickAccessItemsRaw: String = ""')
        self.assert_source_has(source, 'Set(hiddenQuickAccessItemsRaw.split(separator: ",").map(String.init))')
        self.assert_source_has(source, 'ForEach(quickLocations.filter { !hiddenQuickAccessNames.contains($0.name) })')
        self.assert_source_has(source, 'QuickLocation(name: "Pictures"')

    def test_menu_can_hide_and_restore_a_shortcut_without_losing_other_choices(self):
        source = SOURCE.read_text()
        self.assert_source_has(source, 'Menu {\n                        ForEach(quickLocations)')
        self.assert_source_has(source, '.frame(maxWidth: .infinity, alignment: .leading)\n            .padding(.horizontal, 12)')
        self.assert_source_has(source, '.menuIndicator(.hidden)')
        self.assert_source_has(source, 'Toggle(location.name, isOn: Binding(')
        self.assert_source_has(source, 'setQuickAccessVisible(location.name, visible: isVisible)')
        self.assert_source_has(source, 'hiddenQuickAccessItemsRaw = hidden.sorted().joined(separator: ",")')
        self.assert_source_has(source, 'Button("Show All Shortcuts") {\n                            hiddenQuickAccessItemsRaw = ""')


if __name__ == "__main__":
    unittest.main()
