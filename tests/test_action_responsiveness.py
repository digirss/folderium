#!/usr/bin/env python3
"""Source-level guards: user-triggered file actions must not do synchronous
FileManager I/O on the main actor. Companion to test_navigation_responsiveness.py
(which guards navigation). Extract method bodies and assert no blocking calls
remain in MainActor context (SwiftUI View methods default to MainActor)."""
import re
import unittest
from pathlib import Path

APP = Path(__file__).resolve().parents[1] / "Folderium App" / "Folderium" / "DualPaneView.swift"
SOURCE = APP.read_text()


def method_body(name: str, keyword: str = "func") -> str:
    target = keyword + " " + name + "("
    start = SOURCE.find(target)
    assert start != -1, "method " + name + " not found"
    open_brace = SOURCE.find("{", start)
    depth = 1
    i = open_brace + 1
    while depth:
        ch = SOURCE[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        i += 1
    return SOURCE[open_brace + 1:i - 1]


BLOCKING = [
    r"FileManager\.default\.(fileExists|isWritableFile|isReadableFile|trashItem|removeItem|moveItem|copyItem|createDirectory|isDeletibleFile|isDeletableFile)",
    r"try\s+\"[^\"]*\"\.write\(",
    r"SandboxAccessManager\.saveBookmark",
    r"\.bookmarkData\(",
    r"startAccessingSecurityScopedResource",
]
# I/O allowed ONLY inside detached/background context within these methods.
DETACHED_MARKERS = [r"Task\.detached", r"withCheckedThrowingContinuation"]


def sync_io_outside_detached(body: str) -> list[str]:
    """Return blocking calls that appear outside Task.detached blocks."""
    offenders = []
    # Mask out Task.detached { ... } and DispatchQueue.global().async { ... } regions.
    masked = body
    for opener, closer in [("Task.detached", "}")]:
        pass
    # Simpler: split on 'Task.detached' — keep only text before each occurrence
    # (code before the first detached block is definitely main-actor synchronous).
    # Nested closings are approximated by scanning balanced braces.
    idx = 0
    pieces = []
    while True:
        m = re.search(r"Task\.detached", masked[idx:])
        if not m:
            pieces.append(masked[idx:])
            break
        pieces.append(masked[idx:idx + m.start()])
        # skip the balanced block that follows
        b = masked.find("{", idx + m.start())
        if b == -1:
            break
        depth = 1
        j = b + 1
        while depth and j < len(masked):
            if masked[j] == "{":
                depth += 1
            elif masked[j] == "}":
                depth -= 1
            j += 1
        idx = j
    visible = "\n".join(pieces)
    for pattern in BLOCKING:
        for hit in re.finditer(pattern, visible):
            offenders.append(hit.group(0))
    return offenders


class ActionResponsivenessTests(unittest.TestCase):
    def assert_no_sync_io(self, name: str):
        body = method_body(name)
        offenders = sync_io_outside_detached(body)
        self.assertEqual(
            offenders, [],
            f"{name} still does synchronous FileManager I/O on the main actor: {offenders}")

    def test_perform_drop_operation_move_off_main(self):
        self.assert_no_sync_io("performDropOperation")

    def test_paste_files_off_main(self):
        self.assert_no_sync_io("pasteFiles")

    def test_commit_inline_rename_off_main(self):
        self.assert_no_sync_io("commitInlineRename")

    def test_context_menu_trash_off_main(self):
        self.assert_no_sync_io("moveToTrash")

    def test_context_menu_delete_off_main(self):
        self.assert_no_sync_io("deleteFile")

    def test_pane_create_new_folder_off_main(self):
        self.assert_no_sync_io("createNewFolderInActivePane")

    def test_row_create_new_folder_off_main(self):
        self.assert_no_sync_io("createNewFolder")

    def test_row_create_new_file_off_main(self):
        self.assert_no_sync_io("createNewFile")

    def test_select_folder_bookmark_off_main(self):
        # saveBookmark hits the filesystem (bookmarkData + defaults); keep it
        # off the UI thread after the open panel returns.
        body = method_body("selectFolder")
        self.assertEqual(
            sync_io_outside_detached(body), [],
            "selectFolder still does bookmark/FS work on the main actor")

    def test_get_unique_destination_url_off_main(self):
        self.assert_no_sync_io("getUniqueDestinationURL")

    def test_resolve_conflict_destination_off_main(self):
        self.assert_no_sync_io("resolveConflictDestination")

    def test_resolve_drop_conflict_off_main(self):
        self.assert_no_sync_io("resolveDropConflict")


if __name__ == "__main__":
    unittest.main()
