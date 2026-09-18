//
//  OnboardingView.swift
//  AutoFansMac
//
//  First-run disclaimer, the helper explanation, and the recovery prompt for an unclean
//  previous exit (PROMPT.md §6.7.5, §6.8).
//

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var env: AppEnvironment
    var onFinish: () -> Void

    @State private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "fan.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to AutoFansMac").font(.title2.weight(.semibold))
                    Text("\(env.platform.modelIdentifier) · \(env.platform.chipName) · "
                         + "\(env.fans.snapshot.fanCount) fan\(env.fans.snapshot.fanCount == 1 ? "" : "s") detected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                bullet("thermometer.medium",
                       "Reading sensors is always safe and needs no privileges. The Sensors view works right away.")
                bullet("lock.shield",
                       "Writing fan speeds needs a small privileged helper, because macOS only allows root to "
                       + "change fan keys. You will be asked for your administrator password once, when you install it.")
                bullet("exclamationmark.triangle",
                       "You are taking over cooling from macOS. Firmware protections still exist, but a curve that "
                       + "is too weak can let the machine run hot. AutoFansMac keeps a thermal floor that forces "
                       + "every fan to maximum if temperatures get dangerous, and it restores macOS control on quit.")
                bullet("arrow.uturn.backward",
                       "Built-in profiles: Automatic hands every fan back to macOS; Full Blast drives them to maximum.")
            }

            if env.uncleanExitDetected {
                VStack(alignment: .leading, spacing: 6) {
                    Label("The previous session did not shut down cleanly", systemImage: "exclamationmark.octagon")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("Fans may have been left in a custom mode. Choose what to do now — "
                         + "“Restore Automatic” is the safe default.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Restore Automatic") {
                            Task { @MainActor in
                                await env.fans.restoreAllToAuto(reason: "recovery after unclean exit")
                                finish()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Re-apply “\(env.profiles.activeProfileName)”") {
                            Task { @MainActor in
                                await env.applyActiveProfile(reason: "recovery after unclean exit")
                                finish()
                            }
                        }
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            Toggle("I understand that I am controlling the fans myself", isOn: $acknowledged)

            HStack {
                Spacer()
                Button("Not now") { finish() }
                Button("Continue") {
                    finish()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!acknowledged)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: SettingsKey.hasCompletedOnboarding)
        onFinish()
    }
}
