//
//  ProfileEditorView.swift
//  AutoFansMac
//
//  The profile editor: a profile seen as a document — its name and every fan's mode, sensor
//  and ramp — instead of settings that can only be reached through the live fan cards while
//  the profile happens to be active.
//
//  Built-ins are definitions and cannot change, so "editing" one produces a profile of the
//  user's own. That is the same rule the store enforces; here it is visible before saving
//  rather than being the reason an edit quietly vanished.
//

import SwiftUI
import SMCKit

struct ProfileEditorView: View {

    @EnvironmentObject private var env: AppEnvironment
    @AppStorage(SettingsKey.temperatureUnit) private var temperatureUnitRaw = TemperatureUnit.celsius.rawValue

    /// The profile being edited, as it is stored now.
    let source: Profile
    let onSave: (Profile) -> Void
    let onCancel: () -> Void

    @State private var draft: Profile
    @State private var name: String

    init(source: Profile, onSave: @escaping (Profile) -> Void, onCancel: @escaping () -> Void) {
        self.source = source
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: source)
        _name = State(initialValue: source.builtIn ? "\(source.name) (edited)" : source.name)
    }

    private var temperatureUnit: TemperatureUnit {
        TemperatureUnit(rawValue: temperatureUnitRaw) ?? .celsius
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// Every sensor-based fan needs a usable ramp before this can be saved.
    private var rangesAreValid: Bool {
        draft.fans.allSatisfy { $0.mode != .sensor || $0.hasValidTemperatureRange }
    }

    private var canSave: Bool {
        rangesAreValid && !trimmedName.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 580, height: 540)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(source.builtIn ? "Edit “\(source.name)”" : "Edit “\(source.name)”")
                .font(.headline)

            if source.builtIn {
                Text("“\(source.name)” is built-in and cannot be changed. Saving keeps your "
                     + "settings in a new profile called “\(trimmedName.isEmpty ? source.name : trimmedName)”, "
                     + "which becomes the active one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Name") { Text(trimmedName) }
            } else {
                TextField("Profile name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(16)
    }

    // MARK: - Fans

    private var form: some View {
        Form {
            ForEach($draft.fans) { $setting in
                Section(fanName(setting.index)) {
                    Picker("Mode", selection: $setting.mode) {
                        ForEach(FanControlMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch setting.mode {
                    case .auto:
                        Text("macOS controls this fan; AutoFansMac only reads it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .constant:
                        constantEditor(for: $setting)
                    case .sensor:
                        curveEditor(for: $setting)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func constantEditor(for setting: Binding<FanSetting>) -> some View {
        let fan = env.fans.snapshot.fans.first { $0.index == setting.wrappedValue.index }
        let lower = max(fan?.minRPM ?? SafetyBounds.absoluteMinimumRPM, SafetyBounds.absoluteMinimumRPM)
        let upper = max(fan?.maxRPM ?? lower + 1_000, lower + 1)

        return VStack(alignment: .leading, spacing: 6) {
            Toggle("Always this fan's maximum", isOn: Binding(
                get: { setting.wrappedValue.rpm == .maximum },
                set: { isMaximum in
                    setting.wrappedValue.rpm = isMaximum ? .maximum : .value(lower)
                }
            ))
            .toggleStyle(.checkbox)
            .help("Stored as @max, so the profile means “as fast as this fan goes” on any Mac")

            if setting.wrappedValue.rpm != .maximum {
                HStack(spacing: 10) {
                    Slider(value: rpmBinding(setting, maximum: upper), in: lower...upper, step: 50)
                    TextField("RPM", value: rpmBinding(setting, maximum: upper),
                              format: .number.precision(.fractionLength(0)))
                        .frame(width: 72)
                        .textFieldStyle(.roundedBorder)
                    Text("RPM").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func rpmBinding(_ setting: Binding<FanSetting>, maximum: Double) -> Binding<Double> {
        Binding(
            get: { setting.wrappedValue.rpm.resolved(maxRPM: maximum) },
            set: { setting.wrappedValue.rpm = .value($0) }
        )
    }

    private func curveEditor(for setting: Binding<FanSetting>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Sensor").frame(width: 60, alignment: .leading)
                SensorPicker(selection: setting.wrappedValue.sensorKey ?? "") { key, name in
                    setting.wrappedValue.sensorKey = key
                    setting.wrappedValue.sensorName = name
                }
            }

            HStack(spacing: 10) {
                Text("Tmin").frame(width: 60, alignment: .leading)
                TemperatureField(celsius: setting.minTemp, unit: temperatureUnit)
                Text("Tmax")
                TemperatureField(celsius: setting.maxTemp, unit: temperatureUnit)
                if !setting.wrappedValue.hasValidTemperatureRange {
                    Label("Tmin must be below Tmax", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Text("Below Tmin the fan stays with macOS; it reaches its maximum at Tmax.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func fanName(_ index: Int) -> String {
        env.fans.snapshot.fans.first { $0.index == index }?.displayName ?? "Fan \(index + 1)"
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if !rangesAreValid {
                Label("Fix the temperature ranges before saving.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button(source.builtIn ? "Save as new profile" : "Save") {
                var updated = draft
                updated.name = trimmedName
                onSave(updated)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .padding(16)
    }
}
