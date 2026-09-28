import SwiftUI

// MARK: - ConflictStrategyPicker: 衝突策略選擇(PRD §3.5 兩種策略)
// 加入時固定策略;不得由不同複製入口自行變更規則 → 全域單一選擇器

struct ConflictStrategyPicker: View {
    @ObservedObject var bridge = TransferQueueBridge.shared

    var body: some View {
        Menu {
            ForEach(ConflictStrategy.allCases) { strategy in
                Button {
                    bridge.setStrategy(strategy)
                } label: {
                    HStack {
                        if bridge.strategy == strategy {
                            Image(systemName: "checkmark")
                        }
                        Text(strategy.displayName)
                    }
                }
            }
        } label: {
            Label(bridge.strategy.displayName, systemImage: "arrow.triangle.branch")
        }
        .menuStyle(.borderlessButton)
        .help(bridge.strategy.detailText + "。策略於加入佇列時固定。")
    }
}

// MARK: - TransferDrawerView: 底部傳輸進度抽屜(PRD §3.6)
// 可折疊;顯示目前檔名、進度/速度、等待批次、狀態、失敗原因。
// 按鈕只保留:暫停、繼續/重試、移除等待批次、清空已完成。

struct TransferDrawerView: View {
    @ObservedObject var queue = TransferQueue.shared
    @ObservedObject var bridge = TransferQueueBridge.shared
    @AppStorage("folderium.drawerCollapsed") private var collapsed: Bool = false
    @State private var showBatchDetail: UUID?

    private var activeBatches: [QueueBatch] {
        queue.batches.filter { $0.state != .done }
    }

    private var hasAnyActivity: Bool {
        !queue.batches.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if !collapsed {
                drawerContent
                    .frame(maxHeight: 240)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            toggleBar
        }
        .background(FolderiumTheme.controlBackground(isSoftDark: false))
    }

    private var toggleBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() }
            } label: {
                Label(collapsed ? "傳輸(\(activeBatches.count))" : "收起",
                      systemImage: collapsed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)

            if !collapsed {
                Text(queueStateText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                controlButtons
            } else {
                Spacer()
                if let p = queue.currentProgress, let pct = p.percent {
                    Text(String(format: "%.0f%%", pct))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(FolderiumTheme.controlBackground(isSoftDark: false))
        .overlay(alignment: .top) { Divider() }
    }

    private var queueStateText: String {
        if let blocked = queue.dispatchBlockedReason {
            return "⚠️ 需處理:\(blocked)"
        }
        if queue.queuePaused { return "佇列已暫停" }
        if let p = queue.currentProgress {
            var parts: [String] = []
            if let name = p.fileName { parts.append(name) }
            if let pct = p.percent { parts.append(String(format: "%.0f%%", pct)) }
            if let speed = p.speedBytesPerSec, speed > 0 { parts.append(ByteCountFormatter.string(fromByteCount: speed, countStyle: .file) + "/s") }
            return parts.joined(separator: " · ")
        }
        if let note = queue.progressNote { return note }
        if activeBatches.isEmpty { return "沒有等待中的批次" }
        return "等待中:\(activeBatches.count) 批"
    }

    private var controlButtons: some View {
        HStack(spacing: 6) {
            if queue.queuePaused || queue.hasRecoverableWork {
                Button("繼續") { queue.userResume() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(queue.dispatchBlockedReason != nil)
            } else {
                Button("暫停") { queue.pauseQueue() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(activeBatches.isEmpty)
            }

            Button("清空已完成") { queue.clearFinished() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(queue.batches.allSatisfy { $0.state != .done })

            if queue.dispatchBlockedReason != nil {
                Button("確認引擎狀態") { queue.resolveBlockedState() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var drawerContent: some View {
        VStack(spacing: 0) {
            if let err = queue.storeError {
                Text("佇列保存/讀取問題:\(err)")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let err = queue.engineError {
                HStack {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer()
                    Button("知道了") { queue.engineError = nil }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !hasAnyActivity {
                Text("沒有傳輸工作")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        if let progress = queue.currentProgress {
                            progressRow(progress)
                        }
                        ForEach(queue.batches) { batch in
                            batchRow(batch)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func progressRow(_ p: TransferProgress) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                if let name = p.fileName {
                    Text(name).lineLimit(1).truncationMode(.middle)
                } else {
                    Text(queue.progressNote ?? "傳輸中")
                }
                Spacer()
                Text("\(p.transfersNow)/\(p.totalTransfers) 檔")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            if let pct = p.percent {
                ProgressView(value: pct, total: 100)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            HStack {
                if let done = p.transferredBytes, let total = p.totalBytes {
                    Text("\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                }
                if let eta = p.etaSeconds, eta > 0 {
                    Text("ETA \(formatETA(eta))")
                }
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func batchRow(_ batch: QueueBatch) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor(batch.state))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(batch.state.displayName)
                        .font(.system(size: 11, weight: .medium))
                    Text(batch.summaryText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("→ \(batch.destination.split(separator: "/").last ?? "")")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if batch.state == .done {
                    Text(resultSummary(batch))
                        .font(.system(size: 10))
                        .foregroundStyle(batch.results.hasIssues ? .orange : .secondary)
                }
                if let err = batch.lastError, batch.state != .done {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                if batch.state == .needsAttention {
                    Button("重試") { queue.retryBatch(batch.batchId) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(queue.dispatchBlockedReason != nil)
                }
                if batch.state == .waiting || batch.state == .paused || batch.state == .needsAttention || batch.state == .done {
                    Button {
                        showBatchDetail = batch.batchId
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .popover(isPresented: Binding(
                        get: { showBatchDetail == batch.batchId },
                        set: { if !$0 { showBatchDetail = nil } }
                    )) {
                        batchDetailPopover(batch)
                    }
                    Button {
                        queue.removeWaitingBatch(batch.batchId)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .help("移除此批次(不刪除已複製檔案)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { showBatchDetail = showBatchDetail == batch.batchId ? nil : batch.batchId }
    }

    private func batchDetailPopover(_ batch: QueueBatch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("批次詳情").font(.system(size: 12, weight: .semibold))
            Divider()
            detailLine("來源", batch.sourceParent)
            detailLine("目的地", batch.destination)
            detailLine("策略", batch.strategy.displayName)
            detailLine("狀態", batch.state.displayName + (batch.lastError.map { " — \($0)" } ?? ""))
            Divider()
            ForEach(batch.items) { item in
                HStack {
                    Image(systemName: itemIcon(item))
                        .font(.system(size: 10))
                        .foregroundStyle(item.itemState == .failed ? .red : item.itemState == .unsupported ? .orange : .secondary)
                    Text(item.itemName).lineLimit(1)
                    Spacer()
                    Text(item.itemState.displayName)
                        .foregroundStyle(item.itemState == .failed ? .red : item.itemState == .unsupported ? .orange : .secondary)
                }
                .font(.system(size: 11))
            }
        }
        .padding(12)
        .frame(width: 380, alignment: .leading)
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).frame(width: 44, alignment: .leading).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
            Spacer()
        }
        .font(.system(size: 11))
    }

    private func itemIcon(_ item: BatchItem) -> String {
        switch item.itemState {
        case .pending: return item.isDirectory ? "folder" : "doc"
        case .done: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .skippedSameName: return "minus.circle"
        case .unsupported: return "exclamationmark.triangle"
        }
    }

    private func resultSummary(_ batch: QueueBatch) -> String {
        var parts: [String] = []
        let copied = batch.items.filter { $0.itemState == .done }.count
        if copied > 0 { parts.append("已複製 \(copied)") }
        let skipped = batch.results.engineNoTransfer
        if batch.strategy == .addOnly, skipped > 0 {
            parts.append("因同名略過 ≤\(skipped)(引擎判定無須傳輸)") 
        }
        let failed = batch.items.filter { $0.itemState == .failed }.count
        if failed > 0 { parts.append("失敗 \(failed)") }
        let unsupported = batch.items.filter { $0.itemState == .unsupported }.count
        if unsupported > 0 { parts.append("不支援 \(unsupported)") }
        if parts.isEmpty { parts.append("無傳輸") }
        return parts.joined(separator: " · ")
    }

    private func stateColor(_ state: BatchState) -> Color {
        switch state {
        case .waiting: return .gray
        case .running: return .blue
        case .stopping: return .orange
        case .paused: return .yellow
        case .needsAttention: return .red
        case .done: return .green
        }
    }

    private func formatETA(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return String(format: "%dm%02ds", seconds / 60, seconds % 60) }
        return String(format: "%dh%02dm", seconds / 3600, (seconds % 3600) / 60)
    }
}
