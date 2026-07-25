//
//  SystemPanel.swift
//  kero
//

import AppKit
import SwiftUI

/// 右侧下半区 System tab：CLI 指标的紧凑可视化（进度条 / 速率条 / 可达性卡片）。
struct SystemPanel: View {
    @ObservedObject var model: SystemInfoModel
    @ObservedObject private var themeChanges = Theme.changes

    @State private var siteEditor: SiteEditorState?
    @State private var draftName = ""
    @State private var draftURL = ""
    @State private var draftMethod: ReachabilityHTTPMethod = .get

    private var accent: Color { Color(nsColor: Theme.cursor) }

    private enum SiteEditorState: Identifiable {
        case add
        case edit(UUID)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let id): return id.uuidString
            }
        }

        var isAdd: Bool {
            if case .add = self { return true }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    resourceCard
                    // Net + Proxy 同一组，行距与资源区一致。
                    networkGroup
                    reachabilityCard
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.25), value: model.snapshot)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
                .font(SidebarTypography.caption(.medium))
                .foregroundStyle(accent)
            Text("System")
                .font(SidebarTypography.section(.semibold))
                .foregroundStyle(.secondary)
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
            }
            Spacer(minLength: 0)
            Button {
                model.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(SidebarTypography.caption(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("Refresh")
            .disabled(model.isRefreshing)
            .opacity(model.isRefreshing ? 0.45 : 1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    // MARK: - Resource (CPU / Memory / Disk) — 一行一项 + 右对齐等宽折线

    /// 三行折线图统一宽度，保证纵向对齐。
    private static let sparklineWidth: CGFloat = 72
    private static let sparklineHeight: CGFloat = 14

    private var resourceCard: some View {
        VStack(spacing: 0) {
            compactMetricRow(
                title: "CPU",
                percent: model.snapshot.cpuUsagePercent.map { String(format: "%.0f%%", $0) },
                // CPU 无「具体用量」字节值，只显示百分比。
                detail: nil,
                history: model.cpuHistory,
                normalize: { $0 / 100 },
                currentFraction: (model.snapshot.cpuUsagePercent ?? 0) / 100,
                hasValue: model.snapshot.cpuUsagePercent != nil
            )
            compactMetricRow(
                title: "Mem",
                percent: memoryPercentText,
                detail: memoryDetailText,
                // 行内文本 hover 显示 used/total/free 详情。
                textTooltip: memoryTooltip,
                history: model.memoryHistory,
                normalize: { $0 },
                currentFraction: memoryFraction,
                hasValue: model.snapshot.memoryUsedBytes != nil
            )
            compactMetricRow(
                title: "Disk",
                percent: diskPercentText,
                detail: diskDetailText,
                // 行内文本（标题/百分比/累计 W）均可 hover 出详情；折线为最近 1 分钟。
                textTooltip: diskCapacityTooltip,
                history: model.diskWriteHistory,
                normalize: writeRateNormalize(model.diskWriteHistory),
                historyCapacity: SystemInfoModel.diskWriteHistoryCapacity,
                currentFraction: diskUsedFraction,
                hasValue: model.snapshot.diskTotalBytes != nil
                    || model.snapshot.diskWriteBytesSession != nil
            )
        }
        // 无内边距、无背景，尽量贴齐侧栏内容区。
    }

    /// 单行：环 · 标题 · 百分比 · 浅色具体值 · 折线。
    private func compactMetricRow(
        title: String,
        percent: String?,
        detail: String?,
        textTooltip: String? = nil,
        history: [Double],
        normalize: @escaping (Double) -> Double,
        historyCapacity: Int = SystemInfoModel.historyCapacity,
        currentFraction: Double,
        hasValue: Bool
    ) -> some View {
        let fraction = min(max(currentFraction, 0), 1)
        let tint = loadColor(fraction, hasValue: hasValue)
        let series = history.map { min(max(normalize($0), 0), 1) }
        return HStack(spacing: 4) {
            SystemRingProgress(progress: hasValue ? fraction : 0, tint: tint, hasValue: hasValue)
                .frame(width: 11, height: 11)
                // 圆环与后续文本间距 +2pt。
                .padding(.trailing, 2)
            metricTextCluster(title: title, percent: percent, detail: detail, tooltip: textTooltip)
            Spacer(minLength: 2)
            SystemSparkline(
                values: series,
                tint: tint,
                capacity: historyCapacity
            )
            .frame(width: Self.sparklineWidth, height: Self.sparklineHeight)
        }
        .frame(height: 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [title, percent, detail, textTooltip]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        )
    }

    /// 标题 + 百分比 + 详情；可选整段文本 tooltip（如 Disk 容量/写入详情）。
    @ViewBuilder
    private func metricTextCluster(
        title: String,
        percent: String?,
        detail: String?,
        tooltip: String?
    ) -> some View {
        let cluster = HStack(spacing: 4) {
            Text(title)
                .font(SidebarTypography.micro(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            Text(percent ?? "—")
                .font(SidebarTypography.section(.medium))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(SidebarTypography.micro())
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .contentShape(Rectangle())
        if let tooltip, !tooltip.isEmpty {
            cluster.tooltip(tooltip, edge: .above)
        } else {
            cluster
        }
    }

    private var memoryPercentText: String? {
        guard let used = model.snapshot.memoryUsedBytes,
              let total = model.snapshot.memoryTotalBytes, total > 0 else { return nil }
        let pct = Int((Double(used) / Double(total) * 100).rounded())
        return "\(pct)%"
    }

    private var memoryDetailText: String? {
        guard let used = model.snapshot.memoryUsedBytes else { return nil }
        if let total = model.snapshot.memoryTotalBytes, total > 0 {
            return "\(formatBytesShort(used))/\(formatBytesShort(total))"
        }
        return formatBytesShort(used)
    }

    /// 内存 tooltip：总量 / 已用 / 可用 / Wired / Compressed / Swap。
    private var memoryTooltip: String? {
        guard let used = model.snapshot.memoryUsedBytes else { return nil }
        var lines: [String] = []
        if let total = model.snapshot.memoryTotalBytes, total > 0 {
            let free = total > used ? total - used : 0
            let usedPct = Double(used) / Double(total) * 100
            let freePct = Double(free) / Double(total) * 100
            lines = [
                "Total:       \(formatBytes(total))",
                "Used:        \(formatBytes(used))  (\(String(format: "%.1f", usedPct))%)",
                "Free:        \(formatBytes(free))  (\(String(format: "%.1f", freePct))%)",
            ]
        } else {
            lines = ["Used:        \(formatBytes(used))"]
        }
        if let wired = model.snapshot.memoryWiredBytes {
            lines.append("Wired:       \(formatBytes(wired))")
        }
        if let compressed = model.snapshot.memoryCompressedBytes {
            lines.append("Compressed:  \(formatBytes(compressed))")
        }
        if let swapUsed = model.snapshot.memorySwapUsedBytes {
            if let swapTotal = model.snapshot.memorySwapTotalBytes, swapTotal > 0 {
                let pct = Double(swapUsed) / Double(swapTotal) * 100
                lines.append(
                    "Swap:        \(formatBytes(swapUsed)) / \(formatBytes(swapTotal))  (\(String(format: "%.1f", pct))%)"
                )
            } else {
                lines.append("Swap:        \(formatBytes(swapUsed))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private var diskPercentText: String? {
        guard let free = model.snapshot.diskFreeBytes,
              let total = model.snapshot.diskTotalBytes, total > 0 else { return nil }
        let used = total > free ? total - free : 0
        let pct = Int((Double(used) / Double(total) * 100).rounded())
        return "\(pct)%"
    }

    private var diskDetailText: String? {
        // 行内浅色：仅会话累计传输量；累计时长只放 tooltip。
        model.snapshot.diskWriteBytesSession.map { "W \(formatDiskWriteAmount($0))" }
    }

    /// 磁盘百分比 tooltip：容量 + 最近 1 分钟 / 会话累计 / 累计时长。
    private var diskCapacityTooltip: String? {
        guard let free = model.snapshot.diskFreeBytes,
              let total = model.snapshot.diskTotalBytes, total > 0 else { return nil }
        let used = total > free ? total - free : 0
        let usedPct = Double(used) / Double(total) * 100
        let freePct = Double(free) / Double(total) * 100
        var lines = [
            "Volume: /",
            "Total:  \(formatBytes(total))",
            "Used:   \(formatBytes(used))  (\(String(format: "%.1f", usedPct))%)",
            "Free:   \(formatBytes(free))  (\(String(format: "%.1f", freePct))%)",
        ]
        if let lastMin = model.snapshot.diskWriteBytesLastMinute {
            lines.append("Write (last 1 min):  \(formatDiskWriteAmount(lastMin))")
        }
        if let session = model.snapshot.diskWriteBytesSession {
            lines.append("Write (session):     \(formatDiskWriteAmount(session))")
        }
        if let elapsed = model.snapshot.diskWriteElapsedSeconds {
            lines.append("Elapsed:             \(formatElapsed(elapsed))")
        }
        return lines.joined(separator: "\n")
    }

    /// 最近 1 分钟传输量按窗口内峰值归一到 0...1，便于折线纵向铺满。
    private func writeRateNormalize(_ history: [Double]) -> (Double) -> Double {
        let peak = history.max() ?? 0
        let scale = peak > 0 ? peak : 1
        return { value in min(max(value / scale, 0), 1) }
    }

    // MARK: - Network / Proxy（同一组紧凑单行）

    private var networkGroup: some View {
        VStack(spacing: 0) {
            networkRow
            localIPRow
            proxyRow
        }
    }

    /// [图标] Net  ↑ 1.2 MB/s  ↓ 340 KB/s
    private var networkRow: some View {
        let up = model.snapshot.netUploadBytesPerSec
        let down = model.snapshot.netDownloadBytesPerSec
        let upTint = Color(red: 0.55, green: 0.45, blue: 1.0)
        let downTint = Color(red: 0.35, green: 0.65, blue: 1.0)
        return HStack(spacing: 4) {
            Image(systemName: "network")
                .font(SidebarTypography.micro())
                .foregroundStyle(accent)
                .frame(width: 11, height: 11)
                .padding(.trailing, 2)
            Text("Net")
                .font(SidebarTypography.micro(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            networkRateToken(
                systemImage: "arrow.up",
                rate: up,
                tint: upTint
            )
            networkRateToken(
                systemImage: "arrow.down",
                rate: down,
                tint: downTint
            )
            Spacer(minLength: 0)
        }
        .frame(height: 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Net upload \(up.map(formatRate) ?? "—"), download \(down.map(formatRate) ?? "—")"
        )
    }

    private func networkRateToken(systemImage: String, rate: Double?, tint: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(SidebarTypography.micro(.semibold))
                .foregroundStyle(tint)
            Text(rate.map(formatRate) ?? "—")
                .font(SidebarTypography.section(.medium))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    /// [图标] IP  192.168.x.x [复制]  …（复制按钮紧跟文本）
    private var localIPRow: some View {
        let address = model.snapshot.localIPv4Address
        let display = address ?? "—"
        return HStack(spacing: 4) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(SidebarTypography.micro())
                .foregroundStyle(address != nil ? accent : .secondary)
                .frame(width: 11, height: 11)
                .padding(.trailing, 2)
            Text("IP")
                .font(SidebarTypography.micro(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            Text(display)
                .font(SidebarTypography.section(.medium))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .help(localIPHelp)
            if let address {
                Button {
                    copyToPasteboard(address)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(SidebarTypography.micro())
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy IP address")
            }
            Spacer(minLength: 0)
        }
        .frame(height: 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("IP \(display)")
    }

    private var localIPHelp: String {
        if let address = model.snapshot.localIPv4Address {
            if let iface = model.snapshot.localIPv4Interface {
                return "\(iface) · \(address)"
            }
            return address
        }
        return "No local IPv4"
    }

    /// [图标] Proxy  127.0.0.1:1886 [复制]  …（复制按钮紧跟文本，不右对齐）
    private var proxyRow: some View {
        let endpoint = proxyEndpointText
        return HStack(spacing: 4) {
            Image(systemName: proxyEnabled ? "network.badge.shield.half.filled" : "network")
                .font(SidebarTypography.micro())
                .foregroundStyle(proxyEnabled ? accent : .secondary)
                .frame(width: 11, height: 11)
                .padding(.trailing, 2)
            Text("Proxy")
                .font(SidebarTypography.micro(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            Text(endpoint)
                .font(SidebarTypography.section(.medium))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .help(model.snapshot.proxy?.summary ?? "")
            if let exportCmd = proxyShellExportCommand {
                Button {
                    copyToPasteboard(exportCmd)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(SidebarTypography.micro())
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy terminal proxy env\n\(exportCmd)")
            }
            Spacer(minLength: 0)
        }
        .frame(height: 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Proxy \(endpoint)")
    }

    private var proxyEnabled: Bool {
        model.snapshot.proxy?.enabled == true
    }

    /// 行内展示 host:port；PAC / Off 原样。
    private var proxyEndpointText: String {
        guard let proxy = model.snapshot.proxy else { return "—" }
        if !proxy.enabled { return "Off" }
        if let url = proxy.curlProxyURL,
           let stripped = url.range(of: "://").map({ String(url[$0.upperBound...]) }) {
            return stripped
        }
        // summary 形如 "HTTPS 127.0.0.1:1886" 或 "PAC …"
        let parts = proxy.summary.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[1].contains(":") || parts[0] == "PAC" {
            return parts[1]
        }
        return proxy.summary
    }

    /// 可复制的 `export http(s)_proxy=…` 命令；PAC/WPAD 且无显式代理时为 nil。
    private var proxyShellExportCommand: String? {
        model.snapshot.proxy?.shellExportCommand
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Reachability

    private var reachabilityCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            reachabilityHeader
            if model.reachabilityInterval != .off {
                ForEach(model.snapshot.reachability) { item in
                    reachabilityRow(item)
                }
            }
        }
        .sheet(item: $siteEditor) { state in
            siteEditorSheet(state)
        }
    }

    private var reachabilityHeader: some View {
        HStack(spacing: 4) {
            Text("Reachability")
                .font(SidebarTypography.micro(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button {
                model.probeAllNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(SidebarTypography.micro(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Refresh all sites")
            .disabled(model.reachabilityInterval == .off)

            Button {
                draftName = ""
                draftURL = "https://"
                draftMethod = .get
                siteEditor = .add
            } label: {
                Image(systemName: "plus")
                    .font(SidebarTypography.micro(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add site")

            // 原生菜单按钮：文字 + 右侧系统下拉指示器；Toggle 呈现勾选态。
            Menu {
                ForEach(ReachabilityInterval.allCases) { interval in
                    Toggle(isOn: Binding(
                        get: { model.reachabilityInterval == interval },
                        set: { if $0 { model.setReachabilityInterval(interval) } }
                    )) {
                        Text(interval.menuTitle)
                    }
                }
            } label: {
                Text(model.reachabilityInterval.title)
                    .font(SidebarTypography.micro())
            }
            // 不隐藏 menuIndicator，保留右侧系统下拉箭头；tint 与旁侧图标同为 secondary。
            .menuStyle(.borderlessButton)
            .controlSize(.mini)
            .tint(.secondary)
            .fixedSize()
            .help("Sampling interval")
        }
        .frame(height: 18)
    }

    /// [圆点] Name 1ms ---柱状图--
    private func reachabilityRow(_ item: SystemReachabilityItem) -> some View {
        let checking = model.probingSiteIDs.contains(item.id)
        return ReachabilitySiteRow(
            item: item,
            latencyText: latencyText(item.status, checking: checking),
            statusColor: checking ? Color.secondary.opacity(0.45) : statusColor(item.status),
            barWidth: Self.sparklineWidth,
            barHeight: Self.sparklineHeight,
            onDelete: { model.deleteSite(id: item.id) },
            onEdit: {
                draftName = item.name
                draftURL = item.url
                draftMethod = item.method
                siteEditor = .edit(item.id)
            },
            onSetMethod: { model.setSiteMethod(id: item.id, method: $0) },
            onProbeNow: { model.probeSiteNow(id: item.id) },
            onCopyError: {
                guard let error = item.lastError, !error.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(error, forType: .string)
            }
        )
    }

    private func siteEditorSheet(_ state: SiteEditorState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.isAdd ? "Add Site" : "Edit Site")
                .font(SidebarTypography.title())
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
            TextField("URL", text: $draftURL)
                .textFieldStyle(.roundedBorder)
            // GET / HEAD：与右键菜单、curl 探测共用同一 method 字段。
            Picker("Method", selection: $draftMethod) {
                ForEach(ReachabilityHTTPMethod.allCases) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("HTTP method")
            HStack {
                Spacer()
                Button("Cancel") { siteEditor = nil }
                    .keyboardShortcut(.cancelAction)
                Button(state.isAdd ? "Add" : "Save") {
                    commitSiteEditor(state)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || draftURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func commitSiteEditor(_ state: SiteEditorState) {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !url.isEmpty else { return }
        switch state {
        case .add:
            model.addSite(name: name, url: url, method: draftMethod)
        case .edit(let id):
            model.updateSite(id: id, name: name, url: url, method: draftMethod)
        }
        siteEditor = nil
    }

    /// 检测中固定 `...`；成功用紧凑单位，避免 `523ms` 在窄栏被截成 `523...`。
    private func latencyText(_ status: SystemReachabilityStatus, checking: Bool) -> String {
        if checking { return "..." }
        switch status {
        case .unknown: return "..."
        case .reachable(let ms):
            guard let ms else { return "OK" }
            if ms < 1000 { return "\(ms)ms" }
            let seconds = Double(ms) / 1000
            if seconds < 10 {
                return String(format: "%.1fs", seconds)
            }
            return String(format: "%.0fs", seconds)
        case .unreachable:
            return "—"
        }
    }

    // MARK: - Derived values

    private var memoryFraction: Double {
        guard let used = model.snapshot.memoryUsedBytes,
              let total = model.snapshot.memoryTotalBytes, total > 0 else { return 0 }
        return Double(used) / Double(total)
    }

    private var diskUsedFraction: Double {
        guard let free = model.snapshot.diskFreeBytes,
              let total = model.snapshot.diskTotalBytes, total > 0 else { return 0 }
        let used = total > free ? total - free : 0
        return Double(used) / Double(total)
    }

    /// 紧凑单位：1.2G / 512M，省横向空间。
    private func formatBytesShort(_ bytes: UInt64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(bytes)B" }
        if value >= 100 {
            return String(format: "%.0f%@", value, units[unit])
        }
        if value >= 10 {
            return String(format: "%.1f%@", value, units[unit])
        }
        return String(format: "%.2f%@", value, units[unit])
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.04))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }

    /// 低负载偏 accent，升高后转琥珀/红。
    private func loadColor(_ fraction: Double, hasValue: Bool) -> Color {
        guard hasValue else { return .secondary.opacity(0.35) }
        if fraction < 0.55 { return accent }
        if fraction < 0.8 { return Color(red: 0.95, green: 0.65, blue: 0.2) }
        return Color(red: 0.92, green: 0.35, blue: 0.3)
    }

    private func statusColor(_ status: SystemReachabilityStatus) -> Color {
        switch status {
        case .unknown: return .secondary.opacity(0.45)
        case .reachable: return Color(red: 0.25, green: 0.73, blue: 0.31)
        case .unreachable: return Color(red: 0.9, green: 0.35, blue: 0.3)
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        if value >= 100 {
            return String(format: "%.0f %@", value, units[unit])
        }
        if value >= 10 {
            return String(format: "%.1f %@", value, units[unit])
        }
        return String(format: "%.2f %@", value, units[unit])
    }

    private func formatRate(_ bytesPerSec: Double) -> String {
        formatBytes(UInt64(max(0, bytesPerSec.rounded()))) + "/s"
    }

    /// 磁盘传输量（总量，非速率）。
    private func formatDiskWriteAmount(_ bytes: Double) -> String {
        formatBytes(UInt64(max(0, bytes.rounded())))
    }

    /// 累计时长：`<1m` 显示秒，否则 `12m` / `1h 05m`。
    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours == 0 { return "\(minutes)m" }
        return String(format: "%dh %02dm", hours, minutes)
    }
}

// MARK: - Reachability row / bars

/// 带 hover 高亮的站点行。
private struct ReachabilitySiteRow: View {
    let item: SystemReachabilityItem
    let latencyText: String
    let statusColor: Color
    let barWidth: CGFloat
    let barHeight: CGFloat
    let onDelete: () -> Void
    let onEdit: () -> Void
    let onSetMethod: (ReachabilityHTTPMethod) -> Void
    let onProbeNow: () -> Void
    let onCopyError: () -> Void

    @State private var isHovering = false

    private var hasLastError: Bool {
        guard let error = item.lastError else { return false }
        return !error.isEmpty
    }

    private var rowHelp: String {
        var lines = [item.name, item.url, item.method.rawValue]
        if let error = item.lastError, !error.isEmpty {
            lines.append("Last error: \(error)")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(item.name)
                .font(SidebarTypography.micro(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 72, alignment: .leading)
            Text(latencyText)
                .font(SidebarTypography.micro())
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                // 足够放下 `999ms` / `9.9s` / `...`，避免被截成 `523...`
                .frame(width: 40, alignment: .trailing)
            Spacer(minLength: 4)
            // 柱状图整体贴行尾，与上方折线右对齐。
            ReachabilityBarChart(history: item.history)
                .frame(width: barWidth, height: barHeight)
        }
        .padding(.horizontal, 4)
        .frame(height: 18)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.07) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("删除", action: onDelete)
            Button("修改", action: onEdit)
            Divider()
            // Toggle 在 macOS 菜单里呈现为带勾选的单选项。
            ForEach(ReachabilityHTTPMethod.allCases) { method in
                Toggle(isOn: Binding(
                    get: { item.method == method },
                    set: { if $0 { onSetMethod(method) } }
                )) {
                    Text(method.rawValue)
                }
            }
            Divider()
            Button("立即检测", action: onProbeNow)
            Button("Copy error", action: onCopyError)
                .disabled(!hasLastError)
        }
        .help(rowHelp)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name) \(latencyText)")
    }
}

/// 延迟柱状图：失败=红色满高；成功=按相对高度着色（>0.45 为 #A7C900）；
/// 外框与上方折线图同宽，带描边；柱宽上限 4pt。
private struct ReachabilityBarChart: View {
    let history: [ReachabilitySample]

    /// 低延迟成功柱（相对高度 ≤ 0.45）。
    private let okLowColor = Color(red: 0.25, green: 0.73, blue: 0.31)
    /// 较高延迟成功柱（相对高度 > 0.45）→ #A7C900。
    private let okHighColor = Color(red: 0xA7 / 255, green: 0xC9 / 255, blue: 0)
    private let failColor = Color(red: 0.9, green: 0.35, blue: 0.3)
    private let maxBarWidth: CGFloat = 4
    private let spacing: CGFloat = 1
    private let inset: CGFloat = 2
    /// 成功柱相对高度超过此值时改用 okHighColor。
    private let highLatencyHeightThreshold: CGFloat = 0.45

    var body: some View {
        GeometryReader { geo in
            let plotW = max(geo.size.width - inset * 2, 1)
            let plotH = max(geo.size.height - inset * 2, 1)
            let count = max(history.count, 1)
            let ideal = (plotW - spacing * CGFloat(max(count - 1, 0))) / CGFloat(count)
            let barWidth = min(max(ideal, 1), maxBarWidth)
            HStack(alignment: .bottom, spacing: spacing) {
                // 柱子靠右堆叠（与上方折线右缘对齐）。
                Spacer(minLength: 0)
                if history.isEmpty {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: barWidth, height: plotH * 0.2)
                } else {
                    ForEach(Array(history.enumerated()), id: \.offset) { _, sample in
                        let h = ReachabilityBarMetrics.barHeight(for: sample)
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(barColor(sample: sample, height: h))
                            .frame(
                                width: barWidth,
                                height: max(plotH * h, 1)
                            )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(inset)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func barColor(sample: ReachabilitySample, height: CGFloat) -> Color {
        guard sample.ok else { return failColor }
        // 相对高度由延迟映射：越高延迟越黄绿（#A7C900）。
        return height > highLatencyHeightThreshold ? okHighColor : okLowColor
    }
}

// MARK: - Ring progress

/// 圆形环状进度，替代资源行左侧 SF Symbol。
private struct SystemRingProgress: View {
    let progress: Double
    let tint: Color
    var hasValue: Bool = true

    private let lineWidth: CGFloat = 1.5

    var body: some View {
        let clamped = hasValue ? min(max(progress, 0), 1) : 0
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    hasValue ? tint : Color.primary.opacity(0.18),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.25), value: clamped)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Sparkline

/// 固定容量、右对齐的迷你折线。
///
/// 初始 0/1 个点时不画「中间短横」；用与满序列相同的 X 刻度，避免点变多时整条线被横向拉伸。
private struct SystemSparkline: View {
    /// 已归一到 0...1 的采样。
    let values: [Double]
    let tint: Color
    /// 与历史缓冲容量一致，决定 X 轴刻度。
    var capacity: Int = 60

    private let strokeWidth: CGFloat = 1.25
    private let borderInset: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            let plot = CGRect(
                x: borderInset,
                y: borderInset,
                width: max(size.width - borderInset * 2, 1),
                height: max(size.height - borderInset * 2, 1)
            )
            let points = plotPoints(in: plot)

            // 面积 + 折线（≥2 点）
            if points.count >= 2 {
                var fill = Path()
                fill.move(to: CGPoint(x: points[0].x, y: plot.maxY))
                for p in points { fill.addLine(to: p) }
                fill.addLine(to: CGPoint(x: points[points.count - 1].x, y: plot.maxY))
                fill.closeSubpath()
                context.fill(
                    fill,
                    with: .linearGradient(
                        Gradient(colors: [tint.opacity(0.22), tint.opacity(0.02)]),
                        startPoint: CGPoint(x: plot.midX, y: plot.minY),
                        endPoint: CGPoint(x: plot.midX, y: plot.maxY)
                    )
                )

                var line = Path()
                line.move(to: points[0])
                for p in points.dropFirst() { line.addLine(to: p) }
                context.stroke(
                    line,
                    with: .color(tint),
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
                )
            } else if points.count == 1 {
                // 单点：实心圆点落在右对齐刻度上，样式与折线端点一致。
                let p = points[0]
                let r = strokeWidth
                let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                context.fill(dot, with: .color(tint))
            }
            // 0 点：只保留外框，不画伪折线。
        }
        .overlay {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    /// 在绘图区内生成点列。
    /// - 0 点：空
    /// - 1 点：落在右缘（与「折线区域右对齐」一致），画圆点
    /// - ≥2 点：从左到右铺满宽度；缓冲未满时也能得到正常折线，而不是挤在右侧的短段
    private func plotPoints(in plot: CGRect) -> [CGPoint] {
        let samples = Array(values.suffix(max(capacity, 1)))
        guard !samples.isEmpty else { return [] }

        if samples.count == 1 {
            let value = samples[0]
            return [
                CGPoint(
                    x: plot.maxX,
                    y: plot.minY + yOffset(value, height: plot.height)
                ),
            ]
        }

        let stepX = plot.width / CGFloat(samples.count - 1)
        return samples.enumerated().map { index, value in
            CGPoint(
                x: plot.minX + CGFloat(index) * stepX,
                y: plot.minY + yOffset(value, height: plot.height)
            )
        }
    }

    private func yOffset(_ value: Double, height: CGFloat) -> CGFloat {
        let clamped = min(max(value, 0), 1)
        let pad: CGFloat = 1.5
        let usable = max(height - pad * 2, 1)
        return pad + usable * (1 - CGFloat(clamped))
    }
}
