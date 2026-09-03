//
//  DiagnosticsView.swift
//  kero
//


import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class DiagnosticsViewModel: ObservableObject {
    struct ReportItem: Identifiable, Hashable, Sendable {
        let url: URL
        let modifiedAt: Date
        let byteCount: Int64

        var id: URL { url }
    }

    enum Selection: Hashable {
        case live
        case report(URL)
    }

    @Published private(set) var snapshot: RuntimeDiagnostics.LiveSnapshot?
    @Published private(set) var reports: [ReportItem] = []
    @Published private(set) var reportText = ""
    @Published private(set) var reportError: String?
    @Published var selection: Selection = .live

    private var reloadID = UUID()

    func reload() async {
        let id = UUID()
        reloadID = id
        let payload = await Task.detached(priority: .utility) {
            let snapshot = RuntimeDiagnostics.shared.liveSnapshot()
            let reports = Self.loadReports()
            return (snapshot, reports)
        }.value
        guard reloadID == id else { return }
        snapshot = payload.0
        reports = payload.1

        if case let .report(url) = selection {
            if reports.contains(where: { $0.url == url }) {
                await loadReport(url)
            } else {
                selection = .live
                reportText = ""
                reportError = nil
            }
        }
    }

    func select(_ selection: Selection) {
        self.selection = selection
        guard case let .report(url) = selection else {
            reportText = ""
            reportError = nil
            return
        }
        Task { await loadReport(url) }
    }

    func generateReport() {
        RuntimeDiagnostics.shared.generateManualReport()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            await self?.reload()
            guard let self, let report = self.reports.first else { return }
            self.select(.report(report.url))
        }
    }

    func revealSelectionInFinder() {
        let directory = RuntimeDiagnostics.diagnosticsDirectoryURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if case let .report(url) = selection {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(directory)
        }
    }

    func copyReport() {
        guard case .report = selection, !reportText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reportText, forType: .string)
    }

    private func loadReport(_ url: URL) async {
        let result = await Task.detached(priority: .utility) { () -> Result<String, Error> in
            Result { try String(contentsOf: url, encoding: .utf8) }
        }.value
        guard selection == .report(url) else { return }
        switch result {
        case let .success(text):
            reportText = text
            reportError = nil
        case let .failure(error):
            reportText = ""
            reportError = error.localizedDescription
        }
    }

    private nonisolated static func loadReports() -> [ReportItem] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: RuntimeDiagnostics.diagnosticsDirectoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url in
            guard url.lastPathComponent.hasPrefix("runtime-"), url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return ReportItem(
                url: url,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                byteCount: Int64(values.fileSize ?? 0)
            )
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }
}

struct DiagnosticsView: View {
    @StateObject private var model = DiagnosticsViewModel()
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let _ = l10n.language
        VStack(spacing: 0) {
            toolbar
            Divider()
            metrics
            Divider()
            HSplitView {
                reportSidebar
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 310)
                detail
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            while !Task.isCancelled {
                await model.reload()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label(L10n.t("Diagnostics"), systemImage: "stethoscope")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button {
                model.generateReport()
            } label: {
                Label(L10n.t("Generate Report"), systemImage: "doc.badge.plus")
            }
            Button {
                Task { await model.reload() }
            } label: {
                Label(L10n.t("Refresh"), systemImage: "arrow.clockwise")
            }
            Button {
                model.revealSelectionInFinder()
            } label: {
                Label(L10n.t("Open in Finder"), systemImage: "folder")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private var metrics: some View {
        HStack(spacing: 10) {
            metric(
                title: L10n.t("Open File Descriptors"),
                value: model.snapshot.map { "\($0.openFileDescriptors)" } ?? "—"
            )
            metric(
                title: L10n.t("File Descriptor Limit"),
                value: model.snapshot?.softFileDescriptorLimit.map(String.init) ?? "—"
            )
            metric(
                title: L10n.t("Active Operations"),
                value: model.snapshot.map { "\($0.activeOperations.count)" } ?? "—"
            )
            metric(
                title: L10n.t("Recorded Events"),
                value: model.snapshot.map { "\($0.recordedEventCount)" } ?? "—"
            )
            metric(title: L10n.t("Reports"), value: "\(model.reports.count)")
        }
        .padding(12)
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var reportSidebar: some View {
        List(selection: selectionBinding) {
            Section(L10n.t("Current")) {
                Label(L10n.t("Live Status"), systemImage: "waveform.path.ecg")
                    .tag(DiagnosticsViewModel.Selection.live)
            }
            Section(L10n.t("Reports")) {
                ForEach(model.reports) { report in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(report.modifiedAt.formatted(date: .abbreviated, time: .standard))
                            .font(.system(size: 12).monospacedDigit())
                        Text(ByteCountFormatter.string(fromByteCount: report.byteCount, countStyle: .file))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .tag(DiagnosticsViewModel.Selection.report(report.url))
                }
                if model.reports.isEmpty {
                    Text(L10n.t("No diagnostic reports yet."))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .live:
            liveDetail
        case .report:
            reportDetail
        }
    }

    private var liveDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailTitle(L10n.t("Live Events"))
            Divider()
            if let snapshot = model.snapshot, !snapshot.events.isEmpty {
                List {
                    if !snapshot.activeOperations.isEmpty {
                        Section(L10n.t("Active Operations")) {
                            ForEach(snapshot.activeOperations) { operation in
                                HStack {
                                    Label(
                                        "\(operation.category) · \(operation.name)",
                                        systemImage: "hourglass"
                                    )
                                    Spacer()
                                    Text(L10n.format("%d ms", operation.elapsedMilliseconds))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Section(L10n.t("Recorded Events")) {
                        ForEach(snapshot.events) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.system(size: 11, design: .monospaced).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(event.category) · \(event.name)")
                                        .font(.system(size: 12, weight: .medium))
                                    HStack(spacing: 8) {
                                        Text(event.phase)
                                        if let elapsed = event.elapsedMilliseconds {
                                            Text(L10n.format("%d ms", elapsed))
                                                .monospacedDigit()
                                        }
                                        ForEach(event.metadata.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                                            Text("\(item.key)=\(item.value)")
                                        }
                                    }
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                ContentUnavailableView(
                    L10n.t("No diagnostic events yet."),
                    systemImage: "waveform.path.ecg"
                )
            }
        }
    }

    private var reportDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                detailTitle(L10n.t("Report Details"))
                Spacer()
                Button {
                    model.copyReport()
                } label: {
                    Label(L10n.t("Copy Report"), systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .disabled(model.reportText.isEmpty)
                .padding(.trailing, 12)
            }
            Divider()
            if let error = model.reportError {
                ContentUnavailableView(
                    L10n.t("Unable to Read Report"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(model.reportText)
                        .font(.system(size: 11, design: .monospaced).monospacedDigit())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(14)
                }
            }
        }
    }

    private func detailTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(height: 40)
    }

    private var selectionBinding: Binding<DiagnosticsViewModel.Selection?> {
        Binding(
            get: { model.selection },
            set: { selection in
                guard let selection else { return }
                model.select(selection)
            }
        )
    }
}
