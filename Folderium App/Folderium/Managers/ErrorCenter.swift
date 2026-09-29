import SwiftUI

// MARK: - User-visible file-operation error surface (P1)
// Before this, every failed file action only print()ed to console —
// the user saw "nothing happened" and no reason. This center collects
// failures from any thread and renders them as bounded, auto-dismissing
// toasts at the bottom of the window.

struct FileOperationFailure: Identifiable, Equatable {
    let id = UUID()
    let title: String        // e.g. "搬移失敗"
    let message: String      // error.localizedDescription or context
    let date = Date()
}

@MainActor
final class FileOperationErrorCenter: ObservableObject {
    static let shared = FileOperationErrorCenter()

    /// Bounded queue: at most a few toasts visible at once; older ones
    /// are dropped (not stacked forever) so a failing batch cannot flood
    /// the screen.
    static let maxVisible = 3
    static let dismissalDelay: TimeInterval = 6

    @Published private(set) var failures: [FileOperationFailure] = []

    private var dismissalTasks: [UUID: Task<Void, Never>] = [:]

    /// Report from any context. If called off the main actor the message
    /// is scheduled onto it; direct awaits from detached I/O are fine too.
    nonisolated func report(title: String, message: String) {
        Task { @MainActor in
            self.add(title: title, message: message)
        }
    }

    /// Awaitable variant for code already hopping to MainActor.
    func add(title: String, message: String) {
        let failure = FileOperationFailure(title: title, message: message)
        failures.append(failure)
        if failures.count > Self.maxVisible {
            failures.removeFirst(failures.count - Self.maxVisible)
        }
        dismissalTasks[failure.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.dismissalDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss(id: failure.id)
        }
    }

    func dismiss(id: UUID) {
        failures.removeAll { $0.id == id }
        dismissalTasks[id]?.cancel()
        dismissalTasks[id] = nil
    }
}

/// Bottom toast overlay. Mount once at the ContentView root.
struct FileOperationErrorToastOverlay: View {
    @ObservedObject private var center = FileOperationErrorCenter.shared
    @AppStorage("folderium.softDarkThemeEnabled") private var softDarkThemeEnabled: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            ForEach(center.failures) { failure in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.title)
                            .font(.system(size: 12, weight: .semibold))
                        Text(failure.message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 12)
                    Button {
                        center.dismiss(id: failure.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("關閉")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(FolderiumTheme.controlBackground(isSoftDark: softDarkThemeEnabled))
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .frame(maxWidth: 420)
            }
        }
        .padding(.bottom, 14)
        .animation(.easeInOut(duration: 0.18), value: center.failures)
        .allowsHitTesting(!center.failures.isEmpty)
    }
}
