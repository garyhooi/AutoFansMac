//
//  ContentView.swift
//  AutoFansMac
//
//  The main window: a sidebar of sections and the selected detail view.
//  Deliberately plain — the app is a menu-bar utility, so the window is a monitoring
//  and configuration surface rather than a dashboard (PROMPT.md §6.1-§6.6).
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        NavigationSplitView {
            // The selection write is deferred out of the List's update. Binding it straight
            // to `$env.selection` publishes `AppEnvironment` mid-update, which is the
            // "Publishing changes from within view updates" warning seen when switching
            // pages — and the undefined behaviour that comes with it.
            List(AppEnvironment.SidebarItem.allCases, selection: Binding(
                get: { env.selection },
                set: { newValue in deferToNextRunLoop { env.selection = newValue } }
            )) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
            .safeAreaInset(edge: .bottom) {
                helperFooter
            }
        } detail: {
            detail
                .frame(minWidth: 560, minHeight: 420)
        }
        .overlay(alignment: .top) {
            if let banner = env.banner {
                BannerView(banner: banner)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch env.selection {
        case .fans:
            FansView()
        case .sensors:
            SensorsView()
        case .profiles:
            ProfilesView()
        case .settings:
            SettingsView()
        case .diagnostics:
            DiagnosticsView()
        }
    }

    private var helperFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(env.helper.installationState.isUsable ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(env.helper.installationState.isUsable ? "Helper running" : "Monitoring only")
                    .font(.caption)
                Spacer()
            }
            Text(env.helperStatusSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

/// A transient message bar (helper missing, thermal override, profile adapted…).
struct BannerView: View {
    @EnvironmentObject private var env: AppEnvironment
    let banner: AppEnvironment.Banner

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.headline)
                Text(banner.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let actionTitle = banner.actionTitle, let action = banner.action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
            Button {
                env.banner = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.35)))
        .shadow(radius: 6, y: 2)
        .frame(maxWidth: 620)
    }

    private var symbol: String {
        switch banner.kind {
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var tint: Color {
        switch banner.kind {
        case .warning: return .orange
        case .error: return .red
        case .info: return .accentColor
        }
    }
}
