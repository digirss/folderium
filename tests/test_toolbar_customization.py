#!/usr/bin/env python3
"""Source guards for Firefox-style toolbar customization.
Both top rows must render through CustomizableToolbarRow so every row gets:
visibility toggles, reordering, one-click collapse, and persisted state.
Raw HStack toolbars (uncustomizable) must not creep back."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DUAL = (ROOT / "Folderium App" / "Folderium" / "DualPaneView.swift").read_text()
CONTENT = (ROOT / "Folderium App" / "Folderium" / "ContentView.swift").read_text()
CUSTOM = (ROOT / "Folderium App" / "Folderium" / "ToolbarCustomization.swift").read_text()
BUILD_SH = (ROOT / "Folderium App" / "scripts" / "build_app_clt.sh").read_text()


class ToolbarCustomizationTests(unittest.TestCase):
    def test_shared_component_exists(self):
        self.assertIn("struct CustomizableToolbarRow", CUSTOM)
        self.assertIn("struct ToolbarCustomizationMenu", CUSTOM)
        self.assertIn("struct CustomizableToolbarLayout", CUSTOM)

    def test_file_toolbar_uses_customizable_row(self):
        self.assertIn("CustomizableToolbarRow(", DUAL)
        self.assertIn('static let fileToolbarStorageKey = "folderium.toolbar.fileRowLayout"', DUAL)
        self.assertIn("@AppStorage(DualPaneView.fileToolbarCollapsedKey)", DUAL)
        # All seven legacy toolbar groups are addressable items.
        for item_id in ["openFolders", "layout", "clipboard", "fileOps", "history", "hiddenFiles", "columns"]:
            self.assertIn(f'"{item_id}"', DUAL, f"missing toolbar item {item_id}")

    def test_app_row_uses_customizable_row(self):
        self.assertIn("CustomizableToolbarRow(", CONTENT)
        self.assertIn('static let appRowStorageKey = "folderium.toolbar.appRowLayout"', CONTENT)
        for item_id in ["navPane", "preview", "conflictStrategy"]:
            self.assertIn(f'"{item_id}"', CONTENT, f"missing app-row item {item_id}")

    def test_old_hardcoded_app_row_removed(self):
        # The pre-customization top row was a direct HStack of buttons with no
        # customization menu; the new row routes through CustomizableToolbarRow.
        self.assertIn("CustomizableToolbarRow(", CONTENT)
        self.assertNotIn("ToolbarCustomizationMenu", CONTENT[:1500])

    def test_build_script_compiles_new_file(self):
        self.assertIn("ToolbarCustomization.swift", BUILD_SH)

    def test_collapse_state_persisted(self):
        self.assertIn("appRowCollapsed", CONTENT)
        self.assertIn("fileToolbarCollapsed", DUAL)

    def test_menu_never_hides_last_item(self):
        # The customization menu itself must stay reachable: toggling cannot
        # remove the last visible item.
        self.assertIn("guard layout.visible.count > 1 else { return }", CUSTOM)


if __name__ == "__main__":
    unittest.main()
