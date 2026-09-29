#!/usr/bin/env python3
"""Compile the actual loadFiles body with a controlled slow filesystem adapter.
No GUI, preferences or user files are touched. This is fault injection, not SMB.
"""
import os
from pathlib import Path
import subprocess
import tempfile
from test_navigation_responsiveness import body

root = Path(__file__).resolve().parents[1]
source = (root / 'Folderium App/Folderium/DualPaneView.swift').read_text()
load = body(source, 'private func loadFiles()')
permission = body(source, '.task(id: activePanePath)')
# The SwiftUI value-type view permits implicit self in the legacy log; the
# reference-type test harness does not. Normalize only that diagnostic string.
load = load.replace('print("Error loading files from \\(path): \\(error)")',
                    'print("Error loading files from \\(loadPath): \\(error)")')
harness = r'''
import Foundation
import Darwin

struct FileItem {
    let url: URL
    var name: String { url.lastPathComponent }
    var isDirectory: Bool { false }
    init(url: URL) { self.url = url }
}
final class FileManager: @unchecked Sendable {
    static let `default` = FileManager()
    func isWritableFile(atPath: String) -> Bool {
        Thread.sleep(forTimeInterval: 0.4)
        return true
    }
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>) -> Bool {
        if path.contains("timeout") { Thread.sleep(forTimeInterval: 18) }
        if path.contains("slow") { Thread.sleep(forTimeInterval: 0.4) }
        isDirectory.pointee = true
        return !path.contains("error")
    }
    func isReadableFile(atPath: String) -> Bool { true }
    func contentsOfDirectory(at url: URL, includingPropertiesForKeys: [URLResourceKey]?, options: Foundation.FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        [url.appendingPathComponent("entry", isDirectory: false)]
    }
}
@MainActor final class Pane {
    var path = URL(fileURLWithPath: "/slow", isDirectory: true)
    var showHiddenFiles = false
    var isLoading = false
    var errorMessage: String?
    var files: [FileItem] = []
    var selection = Set<URL>()
    var keyboardSelectionAnchor: URL?
    var keyboardSelectionFocus: URL?
    var directoryLoadID = UUID()
    var directoryLoadTask: Task<Void, Never>?
    var directoryLoadTimeoutTask: Task<Void, Never>?
    func applyFiltersAndSorting() {}
    func loadFiles() {
__LOAD__
    }
}
@MainActor final class Permissions {
    var activePanePath = URL(fileURLWithPath: "/slow", isDirectory: true)
    var writableFolderPath: String?
    func update() async {
__PERMISSION__
    }
}
func fail(_ message: String) -> Never { print("FAIL: \(message)"); exit(1) }
Task { @MainActor in
    let permissions = Permissions()
    let started = Date()
    let oldPermission = Task { await permissions.update() }
    try? await Task.sleep(nanoseconds: 50_000_000)
    guard Date().timeIntervalSince(started) < 0.25 else { fail("slow permission probe blocks main actor") }
    oldPermission.cancel()
    permissions.activePanePath = URL(fileURLWithPath: "/new", isDirectory: true)
    await permissions.update()
    await oldPermission.value
    guard permissions.writableFolderPath == "/new" else { fail("stale permission applied") }
    print("PASS: slow permission probe leaves main actor responsive; stale result ignored")
    // Slow A completing after fast B must not overwrite B's rows.
    let pane = Pane()
    pane.loadFiles()
    try? await Task.sleep(nanoseconds: 30_000_000)
    guard pane.isLoading else { fail("slow request did not start") }
    pane.path = URL(fileURLWithPath: "/fast", isDirectory: true)
    pane.loadFiles()
    try? await Task.sleep(nanoseconds: 600_000_000)
    guard pane.files.first?.url.path == "/fast/entry" else { fail("old slow result overwrote new folder") }
    guard !pane.isLoading, pane.errorMessage == nil else { fail("fast folder state incorrect") }
    print("PASS: slow success cannot overwrite new folder")
    // A delayed failure must not set an error on B.
    pane.path = URL(fileURLWithPath: "/slow-error", isDirectory: true)
    pane.loadFiles()
    try? await Task.sleep(nanoseconds: 30_000_000)
    pane.path = URL(fileURLWithPath: "/fast", isDirectory: true)
    pane.loadFiles()
    try? await Task.sleep(nanoseconds: 600_000_000)
    guard pane.errorMessage == nil, !pane.isLoading else { fail("old failure poisoned new folder") }
    print("PASS: slow failure cannot overwrite new folder")
    // A current failure must still be visible and clear old rows.
    pane.path = URL(fileURLWithPath: "/error", isDirectory: true)
    pane.loadFiles()
    try? await Task.sleep(nanoseconds: 100_000_000)
    guard pane.errorMessage != nil, !pane.isLoading, pane.files.isEmpty else { fail("current error hidden or stale rows retained") }
    print("PASS: current error remains visible; no stale rows")
    pane.path = URL(fileURLWithPath: "/timeout", isDirectory: true)
    pane.loadFiles()
    let timeoutStarted = Date()
    while pane.isLoading && Date().timeIntervalSince(timeoutStarted) < 17 {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    print("timeout observed at \(Date().timeIntervalSince(timeoutStarted)) seconds")
    guard !pane.isLoading, pane.errorMessage != nil else { fail("unresponsive filesystem leaves infinite spinner") }
    let timeoutError = pane.errorMessage
    try? await Task.sleep(nanoseconds: 3_200_000_000)
    guard pane.errorMessage == timeoutError, pane.files.isEmpty else { fail("late result undid timeout") }
    print("PASS: timeout ends loading; late completion discarded")
    exit(0)
}
dispatchMain()
'''.replace('__LOAD__', load).replace('__PERMISSION__', permission)
with tempfile.TemporaryDirectory(prefix='folderium-load-test-', dir=os.environ['TMPDIR']) as tmp:
    src = Path(tmp) / 'main.swift'
    binary = Path(tmp) / 'load-smoke'
    src.write_text(harness)
    subprocess.run(['swiftc', '-swift-version', '5', str(src), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
