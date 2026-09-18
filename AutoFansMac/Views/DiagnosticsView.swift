//
//  DiagnosticsView.swift
//  AutoFansMac
//
//  In-app view of the fan-control event ring plus "Export Diagnostics…"
//  (PROTMPT.md §6.6, §6.7.7). Everything here is local; the app makes no network calls.
//

import SwiftUI
import SMCKit

struct DiagnosticsView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var filter: Filter = .all
    @State private var exportedMessage: String?

    enum Filter: String, CaseIterable, Identifiable {
        case all, problems, writes

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .problems: return "Problems"
            case .writes: return "Writes"
            }
        }
    }

    private var entries: [DiagnosticEntry] {
        let all = env.log.entries.reversed().map { $0 }
        switch filter {
        case .all: return Array(all)
        case .problems: return all.filter { $0.level == .failure || $0.level == .warning }
        case .writes: return all.filter { $0.level == .applied || $0.level == .verified }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if entries.isEmpty {
                VStack(spacing: 6) {
                    Text("No events yet").foregroundStyle(.secondary)
                    Text("Fan commands, helper state changes and failures appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(color(for: entry.level))
                            .frame(width: 7, height: 7)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(entry.category).font(.caption.weight(.semibold))
                                Text(Self.time.string(from: entry.timestamp))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.message)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 1)
                }
                .listStyle(.inset)
            }
            Divider()
            hardwareSummary
        }
        .navigationTitle("Diagnostics")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            Spacer()

            if let exportedMessage {
                Text(exportedMessage).font(.caption).foregroundStyle(.secondary)
            }

            Button {
                copyReport()
            } label: {
                Label("Copy report", systemImage: "doc.on.doc")
            }

            Button {
                exportReport()
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }

            Button(role: .destructive) {
                env.log.clear()
            } label: {
                Label("Clear", systemImage: "trash")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var hardwareSummary: some View {
        let snapshot = env.fans.snapshot
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(env.platform.summary)")
                .font(.caption)
            Text("fans \(snapshot.fanCount) · mode key \(snapshot.modeKeyIsLowercase ? "lowercase F%dmd" : "uppercase F%dMd") "
                 + "· Ftst \(snapshot.hasFtst ? "present" : "absent") · FS! \(snapshot.hasForceMask ? "present" : "absent") "
                 + "· unlock \(snapshot.unlockStyle.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("safety \(env.safety.state.displayName) · thermal state \(SafetyMonitor.describe(env.safety.thermalState)) "
                 + "· helper \(env.helper.installationState.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func color(for level: DiagnosticEntry.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .applied: return .blue
        case .verified: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }

    private func copyReport() {
        Task { @MainActor in
            let report = await env.buildDiagnosticsReport()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
            exportedMessage = "Report copied to the clipboard."
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            exportedMessage = nil
        }
    }

    private func exportReport() {
        Task { @MainActor in
            let report = await env.buildDiagnosticsReport()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "AutoFansMac-diagnostics.txt"
            panel.allowedContentTypes = [.plainText]
            if panel.runModal() == .OK, let url = panel.url {
                do {
                    try report.write(to: url, atomically: true, encoding: .utf8)
                    exportedMessage = "Saved to \(url.lastPathComponent)"
                } catch {
                    exportedMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
