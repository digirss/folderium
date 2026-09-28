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

// MARK: - TransfersLimitPicker: 同時傳輸檔案數 N(1~4;下一個作業生效)

struct TransfersLimitPicker: View {
    @ObservedObject var queue = TransferQueue.shared

    var body: some View {
        Menu {
            ForEach(1...4, id: \.self) { n in
                Button {
                    queue.setTransfersLimit(n)
                } label: {
                    HStack {
                        if queue.transfersLimit == n {
                            Image(systemName: "checkmark")
                        }
                        Text("同時傳 \(n) 個檔案")
                    }
                }
            }
        } label: {
            Label("同時 \(queue.transfersLimit)", systemImage: "arrow.triangle.swap.2.circlepath")
        }
        .menuStyle(.borderlessButton)
        .help("同時傳輸的檔案數上限(1~4)。調整後從下一個作業生效。")
    }
}

// MARK: - TransferDrawerView: 底部傳輸進度抽屜(PRD §3.6)
// 加入佇列 → 按「啟動」開始;「暫停」停止並標記只傳一半;再啟動接續。

struct TransferDrawerView: View {
    @ObservedObject var queue = TransferQueue.shared
    @ObservedObject var bridge = TransferQueueBridge.shared
    @AppStorage("folderium.drawerCollapsed") private var collapsed: Bool = false
    @State private var showBatchDetail: UUID?

    private var activeBatches: [QueueBatch] {
        queue.batches.filter { $0.state != .done }
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
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                TransfersLimitPicker()
                controlButtons
            } else {
                Spacer()
                if queue.queueStarted, let p = queue.currentProgress, let pct = p.percent {
                    Text(String(format: "%.0f%%", pct))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else if !activeBatches.isEmpty {
                    Text(queue.queueStarted ? "傳輸中" : "待啟動 \(activeBatches.count) 批")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .overlay(alignment: .top) { Divider() }
    }

    private var queueStateText: String {
        if let blocked = queue.dispatchBlockedReason {
            return "⚠️ 需處理:\(blocked)"
        }
        if let notice = queue.partialNotice {
            return notice
        }
        if !queue.queueStarted {
            let n = queue.hasAnyUndoneWork ? "有批次待啟動" : "沒有等待中的批次"
            return "佇列未啟動 — \(n)(加入的檔案會先排在這裡)"
        }
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
            if queue.queueStarted {
                Button {
                    queue.pauseQueue()
                } label: {
                    Label("暫停", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!queue.hasAnyUndoneWork && queue.currentProgress == nil)
                .help("停止派發並停止目前作業;未完成的檔案會標記,啟動後接續")
            } else {
                Button {
                    queue.startQueue()
                } label: {
                    Label("啟動", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!queue.hasAnyUndoneWork || queue.dispatchBlockedReason != nil)
                .help("開始傳輸佇列;只傳一半的檔案會重傳,已完成的不重傳")
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
                        .lineLimit(3)
                    Spacer()
                    Button("知道了") { queue.engineError = nil }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let notice = queue.partialNotice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 11))
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if queue.batches.isEmpty {
                Text("沒有傳輸工作 — 拖曳或複製貼上檔案會先進入這裡,按「啟動」開始傳輸")
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
                        .foregroundStyle(batch.results.partial > 0 ? .orange : .secondary)
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
                if batch.state != .running && batch.state != .stopping {
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
                        .foregroundStyle(item.itemState == .failed ? .red : item.itemState == .unsupported || item.itemState == .partial ? .orange : .secondary)
                    Text(item.itemName).lineLimit(1)
                    Spacer()
                    Text(item.itemState.displayName)
                        .foregroundStyle(item.itemState == .failed ? .red : item.itemState == .unsupported || item.itemState == .partial ? .orange : .secondary)
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
        case .partial: return "clock.badge.exclamationmark"
        }
    }

    private func resultSummary(_ batch: QueueBatch) -> String {
        var parts: [String] = []
        let copied = batch.items.filter { $0.itemState == .done }.count
        if copied > 0 { parts.append("已複製 \(copied)") }
        let skipped = batch.items.filter { $0.itemState == .skippedSameName }.count
        if skipped > 0 { parts.append("同名略過 \(skipped)") }
        let partial = batch.items.filter { $0.itemState == .partial }.count
        if partial > 0 { parts.append("只傳一半 \(partial)") }
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
